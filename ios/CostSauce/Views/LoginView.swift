// The CostSauce sign-in form — email + emailed 6-digit code (GoTrue OTP),
// plus a disclosed "App-review access" fixed-credential path for App
// Review. Reused both as the initial sign-in screen (CostSauceApp's
// `RootView`) and inside the sync chip's re-auth sheet (`MainTabView`) —
// `onAuthenticated` is the one seam that tells the two call sites apart.

import SwiftUI
import CostSauceKit

struct LoginView: View {
    let appModel: AppModel
    var onAuthenticated: (Session) -> Void

    @State private var email = ""
    @State private var otpSent = false
    @State private var code = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    @State private var reviewerExpanded = false
    @State private var reviewerEmail = ""
    @State private var reviewerCode = ""
    @State private var reviewerBusy = false
    @State private var reviewerError: String?

    var body: some View {
        Form {
            if appModel.config == nil && appModel.configError == nil {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading…")
                        Spacer()
                    }
                }
            } else if let configError = appModel.configError, appModel.config == nil {
                Section {
                    Text(configError).foregroundStyle(.red)
                    Button("Try Again") {
                        Task { await appModel.loadConfig() }
                    }
                }
            } else if appModel.gotrue != nil {
                emailSection
                DisclosureGroup("App-review access", isExpanded: $reviewerExpanded) {
                    reviewerFields
                }
            } else {
                // /config's supabase_url is null — reviewer access is the
                // only sign-in path available (web parity).
                Section("Sign In") {
                    reviewerFields
                }
            }
        }
        .task {
            if appModel.config == nil {
                await appModel.loadConfig()
            }
        }
    }

    // MARK: - email + OTP

    @ViewBuilder
    private var emailSection: some View {
        Section("Sign In") {
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(otpSent)

            if otpSent {
                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                Button("Verify Code") {
                    Task { await verify() }
                }
                .disabled(code.isEmpty || isBusy)
                Button("Resend Code") {
                    Task { await sendCode() }
                }
                .disabled(isBusy)
            } else {
                Button("Send Code") {
                    Task { await sendCode() }
                }
                .disabled(email.isEmpty || isBusy)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            if isBusy {
                ProgressView()
            }
        }
    }

    private func sendCode() async {
        guard let gotrue = appModel.gotrue else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await gotrue.requestOtp(email: email)
            otpSent = true
        } catch let error as ApiError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func verify() async {
        guard let gotrue = appModel.gotrue else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let session = try await gotrue.verifyOtp(email: email, code: code)
            onAuthenticated(session)
        } catch let error as ApiError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - reviewer access

    @ViewBuilder
    private var reviewerFields: some View {
        TextField("Email", text: $reviewerEmail)
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        TextField("Code", text: $reviewerCode)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        Button("Sign In") {
            Task { await reviewerSignIn() }
        }
        .disabled(reviewerEmail.isEmpty || reviewerCode.isEmpty || reviewerBusy)

        if let reviewerError {
            Text(reviewerError).foregroundStyle(.red)
        }
        if reviewerBusy {
            ProgressView()
        }
    }

    private func reviewerSignIn() async {
        reviewerBusy = true
        reviewerError = nil
        defer { reviewerBusy = false }
        do {
            let session = try await appModel.api.reviewerLogin(email: reviewerEmail, code: reviewerCode)
            onAuthenticated(session)
        } catch let error as ApiError {
            reviewerError = error.message
        } catch {
            reviewerError = error.localizedDescription
        }
    }
}
