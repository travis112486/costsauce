# api/services/billing.py
import os
import stripe


class BillingError(RuntimeError):
    pass


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
    stripe.api_key = os.environ.get("STRIPE_API_KEY", "")
    if not stripe.api_key:
        raise BillingError(
            f"STRIPE_API_KEY is not configured; refusing to silently skip "
            f"billing cancellation for customer {customer_id}"
        )
    try:
        for sub in stripe.Subscription.list(
            customer=customer_id, status="active"
        ).auto_paging_iter():
            stripe.Subscription.delete(sub.id)
    except stripe.error.StripeError as e:
        raise BillingError(str(e)) from e
