import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @Binding var isLoggedIn: Bool

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack {
                Spacer()

                // 標題
                Text("Create Account")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                VStack(spacing: 16) {

                    // Google 登入
                    Button(action: {
                        print("Google 登入成功")
                        isLoggedIn = true
                    }) {
                        SocialLoginButton(
                            imageName: "google_icon",
                            title: "Sign in with Google"
                        )
                    }

                    // Apple 登入
                    SignInWithAppleButton(
                        .signIn,
                        onRequest: { request in
                            request.requestedScopes = [.fullName, .email]
                        },
                        onCompletion: { result in
                            switch result {
                            case .success(_):
                                print("Apple 登入成功")
                                isLoggedIn = true
                            case .failure(let error):
                                print("登入失敗：\(error.localizedDescription)")
                            }
                        }
                    )
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 55)
                    .cornerRadius(10)
                }
                .padding(.horizontal, 24)

                Spacer()
            }
        }
    }
}

struct SocialLoginButton: View {
    let imageName: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(imageName)
                .resizable()
                .frame(width: 24, height: 24)

            Text(title)
                .font(.system(size: 21, weight: .medium))
        }
        .foregroundColor(.black)
        .frame(maxWidth: .infinity)
        .frame(height: 55)
        .background(Color(.white))
        .cornerRadius(10)
    }
}

#Preview {
    LoginView(isLoggedIn: .constant(false))
}
