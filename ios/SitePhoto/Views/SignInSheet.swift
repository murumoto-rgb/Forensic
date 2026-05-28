import SwiftUI

/// Full-screen sign-in / sign-up sheet presented when `AuthService.session`
/// is nil. Cannot be dismissed by swipe — the user must either
/// successfully sign in or sign up. (Sign-up with email-confirmation
/// disabled yields an immediate session; sign-up with confirmation
/// enabled — the Supabase default — shows a "check your inbox"
/// message and waits for the user to click the email link and
/// then sign in.)
struct SignInSheet: View {
    var auth: AuthService

    @State private var mode: Mode = .signIn
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String?
    @State private var isSubmitting: Bool = false
    @State private var needsConfirmation: Bool = false

    enum Mode {
        case signIn
        case signUp
    }

    var body: some View {
        NavigationStack {
            Form {
                if needsConfirmation {
                    Section {
                        Label(
                            "Check your inbox for a confirmation link. After clicking it, come back here and sign in.",
                            systemImage: "envelope.badge"
                        )
                        .foregroundStyle(.green)
                    }
                    Section {
                        Button("Back to sign in") {
                            needsConfirmation = false
                            mode = .signIn
                        }
                    }
                } else {
                    Section {
                        TextField("Email", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(
                                mode == .signIn ? .password : .newPassword
                            )
                    } footer: {
                        if mode == .signUp {
                            Text("8 characters or more.")
                        }
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                    }

                    Section {
                        Button(action: submit) {
                            HStack {
                                Spacer()
                                if isSubmitting {
                                    ProgressView()
                                } else {
                                    Text(mode == .signIn ? "Sign in" : "Create account")
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                            }
                        }
                        .disabled(!canSubmit)
                    }

                    Section {
                        Button(
                            mode == .signIn
                                ? "Don't have an account? Create one"
                                : "Already have an account? Sign in"
                        ) {
                            mode = (mode == .signIn) ? .signUp : .signIn
                            errorMessage = nil
                        }
                        .font(.callout)
                    }
                }
            }
            .navigationTitle("SitePhoto - Forensic")
            .navigationBarTitleDisplayMode(.large)
        }
        .interactiveDismissDisabled(true)
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !email.isEmpty
            && password.count >= (mode == .signUp ? 8 : 1)
    }

    private func submit() {
        Task {
            isSubmitting = true
            errorMessage = nil
            defer { isSubmitting = false }
            do {
                switch mode {
                case .signIn:
                    try await auth.signIn(email: email, password: password)
                case .signUp:
                    let pending = try await auth.signUp(email: email, password: password)
                    if pending {
                        needsConfirmation = true
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
