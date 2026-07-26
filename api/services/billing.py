# api/services/billing.py
import asyncio
import os
import stripe


class BillingError(RuntimeError):
    pass


# Statuses a subscription can be in where it can no longer bill anybody and
# there is nothing left to cancel. Everything else -- active, trialing,
# past_due, unpaid, paused -- gets cancelled.
#
# Task 11 correction 5: the first version of this function filtered
# `status="active"`, which silently skipped trialing, past_due and paused
# subscriptions. That is NOT acceptable for a deletion flow and the decision
# is recorded here rather than left to the caller: a `trialing` subscription
# left alone converts and starts charging a customer whose organization no
# longer exists, and `past_due` keeps dunning them. Omitting the filter is
# what Stripe documents as "all subscriptions that have not been canceled",
# and the terminal states above are then dropped client-side so an
# already-dead `incomplete_expired` row cannot turn a deletion into a 404.
_TERMINAL_STATUSES = frozenset({"canceled", "incomplete_expired"})


def _cancel_subscription_sync(customer_id: str) -> None:
    """The actual stripe-python work. Synchronous and blocking by nature --
    stripe-python has no async client here -- so it is deliberately isolated
    in its own function and run on a worker thread by the coroutine below
    (Task 11 correction 6). Called directly inside an `async def`, a Stripe
    round trip stalls the whole event loop, and it is being made at the exact
    moment a user is waiting on an irreversible request.
    """
    stripe.api_key = os.environ.get("STRIPE_API_KEY", "")
    if not stripe.api_key:
        raise BillingError(
            f"STRIPE_API_KEY is not configured; refusing to silently skip "
            f"billing cancellation for customer {customer_id}"
        )
    try:
        for sub in stripe.Subscription.list(customer=customer_id).auto_paging_iter():
            if sub.status in _TERMINAL_STATUSES:
                continue
            stripe.Subscription.delete(sub.id)
    except stripe.error.StripeError as e:
        raise BillingError(str(e)) from e


async def cancel_subscription(customer_id: str | None) -> None:
    """Cancel immediately on deletion confirm, not after the 30-day grace.

    Two different "nothing to do" cases live in here, and only one of them
    is allowed to be quiet:

    * `customer_id` falsy -- there is no Stripe customer on file for this
      org. True for every org today (Task 11 adds
      `organizations.stripe_customer_id`; until then this is always called
      with None) and also true for an org that never subscribed. Genuinely
      nothing to cancel, so this returns silently.

    * `STRIPE_API_KEY` unset/blank while a real `customer_id` was passed --
      NOT the same kind of nothing. This is a deployment misconfiguration
      encountered mid-deletion, after (or about to be followed by) telling
      the user their subscription is cancelled. Swallowing it here would
      leave Stripe still billing a customer who was told billing had
      stopped, with no org record left afterward to notice the mismatch.
      That is worse than a loud failure, so this raises BillingError instead
      of the brief's original silent `return`. Task 11 decides what to do
      with that exception (retry, alert, abort the deletion) -- this
      function's job is only to make sure it can't be missed.
    """
    if not customer_id:
        return
    await asyncio.to_thread(_cancel_subscription_sync, customer_id)
