import SwiftUI

/// Gmail, with the setup it needs written out in full, because none of it
/// can be done from inside the app and getting one step wrong fails with an
/// error that names none of them.
struct EmailSettingsView: View {
    @Environment(BellStore.self) private var store
    @Environment(AppSession.self) private var session

    @State private var clientID = GmailAccount.clientID ?? ""
    @State private var lastResult: String?

    private var gmail: GmailAccount { session.gmail }

    var body: some View {
        Form {
            Section {
                if gmail.isSignedIn {
                    LabeledContent("Signed in", value: gmail.address ?? "Gmail")
                    if let checked = gmail.lastChecked {
                        LabeledContent("Last checked") {
                            Text(checked, format: .relative(presentation: .named))
                                .foregroundStyle(Bell.Content.secondary)
                        }
                    }
                    Button(gmail.isWorking ? "Checking…" : "Check now") {
                        Task {
                            let count = await gmail.check(into: session.inbox, store: store, force: true)
                            lastResult = count == 0 ? "Nothing new." : "\(count) new message\(count == 1 ? "" : "s") read into your inbox."
                        }
                    }
                    .disabled(gmail.isWorking)
                    if let lastResult { Text(lastResult).font(Bell.Type_.caption).foregroundStyle(Bell.Content.secondary) }
                    Button("Sign out", role: .destructive) { Task { await gmail.signOut() } }
                } else {
                    TextField("iOS client ID", text: $clientID, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Bell.Type_.data(13, weight: .regular))
                        .onChange(of: clientID) { _, value in
                            GmailAccount.clientID = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    Button("Sign in with Google") { Task { await gmail.signIn() } }
                        .disabled(GmailOAuth.redirectScheme(for: clientID.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                }
                if let error = gmail.lastError {
                    Text(error).font(Bell.Type_.caption).foregroundStyle(Bell.Signal.urgent)
                }
            } header: {
                Text("Gmail")
            } footer: {
                Text("Bell reads only recent mail that mentions exams, deadlines, meetings and the like, and puts "
                     + "what it finds in your inbox to review, the same as anything you share to it. Mail is read on "
                     + "this phone; nothing goes anywhere but between Bell and Google. Read-only: Bell can't send, "
                     + "delete or change anything.")
            }

            if !gmail.isSignedIn {
                Section("Setting it up (once, about ten minutes)") {
                    step(1, "On a computer, open console.cloud.google.com and create a project (any name).")
                    step(2, "APIs & Services > Library: enable the Gmail API.")
                    step(3, "OAuth consent screen: choose External, fill in an app name and your email, add the scope "
                         + "gmail.readonly, and add your own Gmail address under Test users. Leave it in Testing.")
                    step(4, "Credentials > Create credentials > OAuth client ID > iOS. Bundle ID: com.yourteam.bell.")
                    step(5, "Copy the client ID it gives you (it ends in .apps.googleusercontent.com) into the field above.")
                }
                Section {
                    Text("Because the app stays in Google's Testing mode, Google ends the sign-in every 7 days and "
                         + "Bell will ask you to sign in again. Publishing it to avoid that needs Google's security "
                         + "review for Gmail access, which isn't realistic for a personal app. A free developer account "
                         + "already rebuilds weekly, so in practice it's one more tap on the same day.")
                        .font(Bell.Type_.caption)
                        .foregroundStyle(Bell.Content.secondary)
                } header: {
                    Text("The catch")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Bell.Surface.canvas)
        .navigationTitle("Email")
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Bell.Space.base) {
            Text("\(n)").font(Bell.Type_.data(15, weight: .semibold)).foregroundStyle(Bell.Signal.inferred)
            Text(text).font(Bell.Type_.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}
