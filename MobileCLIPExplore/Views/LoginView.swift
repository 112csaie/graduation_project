import PhotosUI
import SwiftUI

// MARK: - 開始使用（本機帳號）
//
// App 沒有雲端帳號：照片分析、tag、筆記都只存在這支手機。
// 以前的登入／註冊頁要求密碼，但密碼從來沒有被檢查，容易讓人以為資料有備份到雲端，
// 所以改成「輸入名字就能開始」。一支手機一個使用者，不再詢問 Email；
// 以前用 Email 區分的使用者，登出再進來仍沿用同一個 Email（同一份資料）。

struct LoginView: View {
    @Binding var isLoggedIn: Bool

    @AppStorage("userName") private var savedName = ""
    @AppStorage("savedEmail") private var savedEmail = ""

    @State private var name = ""
    @State private var email = ""
    @FocusState private var focusedField: Field?
    @State private var floating = false
    @State private var showAvatarEditor = false

    private enum Field { case name, email }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }

    private var emailIsValid: Bool {
        guard !trimmedEmail.isEmpty else { return true }   // 選填
        let pattern = #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return trimmedEmail.range(of: pattern, options: .regularExpression) != nil
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    VStack(alignment: .leading, spacing: 20) {
                        // 頭貼（選填）：點了可以挑圖案和顏色，或用一張照片
                        HStack(spacing: 14) {
                            Button(action: { showAvatarEditor = true }) {
                                UserAvatarView(name: name, size: 72)
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: "pencil")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(Theme.onAccent)
                                            .frame(width: 26, height: 26)
                                            .background(Theme.accent)
                                            .clipShape(Circle())
                                            .overlay(Circle().stroke(Theme.background, lineWidth: 3))
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("設計頭貼")
                            VStack(alignment: .leading, spacing: 3) {
                                Text("頭貼")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(Theme.text)
                                Text("挑個圖案和顏色，或用一張喜歡的照片")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.secondaryText)
                            }
                        }

                        field(label: "我該怎麼稱呼你/妳？", placeholder: "例如：小明", text: $name, field: .name)

                        privacyNote

                        Button(action: start) {
                            HStack(spacing: 8) {
                                Text(name.trimmingCharacters(in: .whitespaces).isEmpty ? "開始整理我的照片" : "開始吧，\(name.trimmingCharacters(in: .whitespaces))")
                                    .lineLimit(1)
                                Image(systemName: "arrow.right")
                            }
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(emailIsValid ? Theme.onAccent : Theme.text.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(emailIsValid ? Theme.accent : Theme.surface(0.2))
                            .clipShape(Capsule())
                        }
                        .disabled(!emailIsValid)
                        .padding(.bottom, 40)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                }
            }
        }
        .onTapGesture { focusedField = nil }
        .sheet(isPresented: $showAvatarEditor) { AvatarEditorSheet(name: name) }
        .onAppear {
            // 登出後再進來：帶入上次的名字。
            // 不再詢問 Email（一支手機一個使用者）；以前用 Email 建立的使用者照樣沿用同一份資料。
            if name.isEmpty { name = savedName }
            if email.isEmpty { email = savedEmail }
        }
    }

    /// 上方插圖：三張疊在一起的照片卡（愛心、地點、selfIE 圖示），旁邊飄著幾個像搜尋建議的小標籤
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                photoCard(icon: "mappin.and.ellipse", fill: Theme.surface(0.3), angle: -12, x: -70, y: 12)
                photoCard(icon: "heart.fill", fill: Theme.tile, angle: 10, x: 70, y: 14)
                photoCard(icon: "selfie", fill: Theme.accent, angle: 0, x: 0, y: 0, iconColor: Theme.onAccent)
                    .scaleEffect(1.08)
                floatingChip("上個月的拉麵", x: -88, y: -78)
                floatingChip("#貓咪", x: 104, y: -66)
                floatingChip("嘉義兩日遊", x: 82, y: 92)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 230)
            .offset(y: floating ? -4 : 4)
            .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: floating)
            .onAppear { floating = true }

            VStack(alignment: .leading, spacing: 8) {
                SelfieWordmark(size: 46)
                Text(AppBrand.slogan)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(Theme.text)
                Text("用一句話找照片，AI 幫你/妳看懂、分類每一張。")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
    }

    private func photoCard(icon: String, fill: Color, angle: Double, x: CGFloat, y: CGFloat,
                           iconColor: Color = Theme.text) -> some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(fill)
            .frame(width: 120, height: 150)
            .overlay(
                Group {
                    if icon == "selfie" {
                        SelfieGlyph(size: 70, color: iconColor)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(iconColor)
                    }
                }
            )
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.background, lineWidth: 4))
            .rotationEffect(.degrees(angle))
            .offset(x: x, y: y)
    }

    private func floatingChip(_ text: String, x: CGFloat, y: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.card)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
            .offset(x: x, y: y)
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.onAccent)
                .frame(width: 36, height: 36)
                .background(Theme.accent)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("照片只留在這支手機")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.text)
                Text("不需要密碼，也沒有雲端帳號。分析、tag、筆記都存在手機上，不會修改或刪除你/妳的照片；刪除 App 時這些資料會一起刪除。")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .themeCard(radius: 22)
    }

    private func field(label: String, placeholder: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.text)
            TextField(placeholder, text: text)
                .font(.system(size: 17))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(field == .email)
                .keyboardType(field == .email ? .emailAddress : .default)
                .focused($focusedField, equals: field)
                .foregroundColor(Theme.text)
                .padding(.horizontal, 20)
                .padding(.vertical, 15)
                .background(Theme.card)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(focusedField == field ? Theme.highlight : Theme.border,
                                     lineWidth: focusedField == field ? 2 : 0.5)
                )
        }
    }

    private func start() {
        savedName = name.trimmingCharacters(in: .whitespaces)
        savedEmail = trimmedEmail
        // 建立／取得本機使用者 ID（偏好、tag 與 AI 資料擁有權依此區分）；新使用者接著會看到個人化設定
        PersonalizationService.shared.signIn(email: savedEmail, displayName: savedName)
        isLoggedIn = true
    }
}

#Preview {
    LoginView(isLoggedIn: .constant(false))
}


// MARK: - 頭貼

/// 使用者自己設計的頭貼：圖案＋顏色，或一張照片（複製一份縮小的存在 App 裡，不會動到原始照片）。
/// 沒設定時顯示名字的第一個字。
enum UserAvatar {
    static let kindKey = "avatarKind"        // "initial"、"symbol"、"photo"
    static let symbolKey = "avatarSymbol"
    static let colorKey = "avatarColor"

    static let symbols = ["cat.fill", "dog.fill", "hare.fill", "bird.fill", "fish.fill", "tortoise.fill",
                          "star.fill", "heart.fill", "camera.fill", "leaf.fill", "cloud.fill", "music.note",
                          "gamecontroller.fill", "cup.and.saucer.fill", "airplane", "sun.max.fill"]

    /// 頭貼底色：灰藍色票＋一個暖色（俏皮一點）
    static let colors: [Color] = [Theme.accent, Theme.info, Theme.tile, Color(Theme.praiseGiving), Color(UIColor(hex: 0xF2C6B4))]

    static func iconColor(_ index: Int) -> Color { index == 2 ? Theme.text : Theme.onAccent }

    static var photoURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("avatar.jpg")
    }

    /// 存一份正方形、400px 的頭貼照片（App 自己的檔案）
    static func savePhoto(_ image: UIImage) -> Bool {
        let side = min(image.size.width, image.size.height)
        let origin = CGPoint(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2)
        let target = CGSize(width: 400, height: 400)
        let renderer = UIGraphicsImageRenderer(size: target)
        let square = renderer.image { _ in
            image.draw(in: CGRect(x: -origin.x * 400 / side, y: -origin.y * 400 / side,
                                  width: image.size.width * 400 / side, height: image.size.height * 400 / side))
        }
        guard let data = square.jpegData(compressionQuality: 0.85) else { return false }
        return (try? data.write(to: photoURL, options: .atomic)) != nil
    }

    static func loadPhoto() -> UIImage? { UIImage(contentsOfFile: photoURL.path) }

    /// 存使用者裁好的頭貼（已經是正方形）
    static func saveCropped(_ image: UIImage) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return false }
        return (try? data.write(to: photoURL, options: .atomic)) != nil
    }
}

/// 顯示頭貼（登入頁、我的、設定共用）
struct UserAvatarView: View {
    var name: String
    var size: CGFloat = 50
    @AppStorage(UserAvatar.kindKey) private var kind = "initial"
    @AppStorage(UserAvatar.symbolKey) private var symbol = "cat.fill"
    @AppStorage(UserAvatar.colorKey) private var colorIndex = 0
    /// 換照片後重新讀檔
    @AppStorage("avatarPhotoVersion") private var photoVersion = 0

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "你" : String(trimmed.prefix(1)).uppercased()
    }

    var body: some View {
        let index = min(max(colorIndex, 0), UserAvatar.colors.count - 1)
        ZStack {
            if kind == "photo", let photo = UserAvatar.loadPhoto() {
                Image(uiImage: photo).resizable().scaledToFill()
            } else if kind == "symbol" {
                UserAvatar.colors[index]
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .bold))
                    .foregroundColor(UserAvatar.iconColor(index))
            } else {
                Theme.tile
                Text(initial)
                    .font(.system(size: size * 0.4, weight: .heavy))
                    .foregroundColor(Theme.text)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .id(photoVersion)
    }
}

/// 設計頭貼：上面是預覽，選「圖案」（圖示＋底色）或「照片」，也可以改回名字的第一個字
struct AvatarEditorSheet: View {
    var name: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UserAvatar.kindKey) private var kind = "initial"
    @AppStorage(UserAvatar.symbolKey) private var symbol = "cat.fill"
    @AppStorage(UserAvatar.colorKey) private var colorIndex = 0
    @AppStorage("avatarPhotoVersion") private var photoVersion = 0
    @State private var pickerItem: PhotosPickerItem?
    @State private var error: String?
    /// 選好照片後先讓使用者裁切
    @State private var cropping: CropRequest?

    private struct CropRequest: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    UserAvatarView(name: name, size: 110)
                        .padding(.top, 12)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: symbol)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("挑一個圖案")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Theme.text)
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(UserAvatar.symbols, id: \.self) { item in
                                let selected = kind == "symbol" && symbol == item
                                Button(action: {
                                    symbol = item
                                    kind = "symbol"
                                }) {
                                    Image(systemName: item)
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundColor(selected ? Theme.onAccent : Theme.text)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 58)
                                        .background(selected ? Theme.accent : Theme.card)
                                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                    .stroke(selected ? Color.clear : Theme.border, lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Text("底色")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Theme.text)
                            .padding(.top, 6)
                        HStack(spacing: 12) {
                            ForEach(UserAvatar.colors.indices, id: \.self) { index in
                                Button(action: {
                                    colorIndex = index
                                    if kind != "symbol" { kind = "symbol" }
                                }) {
                                    Circle()
                                        .fill(UserAvatar.colors[index])
                                        .frame(width: 40, height: 40)
                                        .overlay(Circle().stroke(Theme.text, lineWidth: colorIndex == index ? 3 : 0))
                                        .overlay(Circle().stroke(Theme.border, lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("底色 \(index + 1)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("選一張照片", systemImage: "photo")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Theme.accent)
                            .clipShape(Capsule())
                    }

                    Button("用名字的第一個字就好") { kind = "initial" }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.secondaryText)

                    if let error {
                        Text(error).font(.system(size: 13)).foregroundColor(.orange)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("設計頭貼")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.fontWeight(.bold)
                }
            }
        }
        .fullScreenCover(item: $cropping) { request in
            AvatarCropView(image: request.image) { cropped in
                if UserAvatar.saveCropped(cropped) {
                    kind = "photo"
                    photoVersion += 1
                } else {
                    error = "存不了這張頭貼，請再試一次。"
                }
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                await MainActor.run {
                    if let data, let image = UIImage(data: data) {
                        cropping = CropRequest(image: image)   // 先裁切，按「使用」才存
                        error = nil
                    } else {
                        error = "讀不到這張照片，請換一張試試。"
                    }
                    pickerItem = nil
                }
            }
        }
    }
}


// MARK: - 裁切頭貼

/// 裁切頭貼：照片放在圓框後面，雙指縮放、拖曳調整位置，按「使用」裁成正方形（400×400）。
/// 只處理 App 裡的這份複本，不會修改原本的照片。
struct AvatarCropView: View {
    let image: UIImage
    let onDone: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let cropSize: CGFloat = 280
    private let maxScale: CGFloat = 5

    /// 縮放 1 倍時，照片短邊剛好填滿圓框
    private var baseScale: CGFloat { cropSize / max(1, min(image.size.width, image.size.height)) }
    private var displaySize: CGSize {
        CGSize(width: image.size.width * baseScale * scale, height: image.size.height * baseScale * scale)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 放在 overlay 裡：放大的照片不會把整個畫面撐大（按鈕才不會被推出螢幕）
            Color.clear
                .overlay {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: displaySize.width, height: displaySize.height)
                        .offset(offset)
                }
                .clipped()

            // 圓框以外變暗
            Rectangle()
                .fill(Color.black.opacity(0.6))
                .mask(
                    ZStack {
                        Rectangle()
                        Circle().frame(width: cropSize, height: cropSize).blendMode(.destinationOut)
                    }
                    .compositingGroup()
                )
                .allowsHitTesting(false)
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 2)
                .frame(width: cropSize, height: cropSize)
                .allowsHitTesting(false)

            VStack {
                Text("拖曳和縮放，把要的部分放進圓框")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.top, 24)
                Spacer()
                HStack(spacing: 14) {
                    Button(action: { dismiss() }) {
                        Text("取消")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Button(action: {
                        onDone(renderCrop())
                        dismiss()
                    }) {
                        Text("使用")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Theme.accent)
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            SimultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(max(lastScale * value, 1), maxScale)
                        offset = clamped(offset)
                    }
                    .onEnded { _ in
                        lastScale = scale
                        offset = clamped(offset)
                        lastOffset = offset
                    },
                DragGesture()
                    .onChanged { value in
                        offset = clamped(CGSize(width: lastOffset.width + value.translation.width,
                                                height: lastOffset.height + value.translation.height))
                    }
                    .onEnded { _ in lastOffset = offset }
            )
        )
    }

    /// 照片一定蓋滿圓框，不會露出空白
    private func clamped(_ value: CGSize) -> CGSize {
        let maxX = max(0, (displaySize.width - cropSize) / 2)
        let maxY = max(0, (displaySize.height - cropSize) / 2)
        return CGSize(width: min(max(value.width, -maxX), maxX), height: min(max(value.height, -maxY), maxY))
    }

    /// 依目前的縮放與位置，切出圓框裡的正方形
    private func renderCrop() -> UIImage {
        let pointsPerImageUnit = baseScale * scale
        let side = cropSize / pointsPerImageUnit                     // 圓框在原圖上的邊長
        let centerX = image.size.width / 2 - offset.width / pointsPerImageUnit
        let centerY = image.size.height / 2 - offset.height / pointsPerImageUnit
        let cropRect = CGRect(x: centerX - side / 2, y: centerY - side / 2, width: side, height: side)
        let output: CGFloat = 400
        let k = output / side
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: output, height: output), format: format).image { _ in
            image.draw(in: CGRect(x: -cropRect.minX * k, y: -cropRect.minY * k,
                                  width: image.size.width * k, height: image.size.height * k))
        }
    }
}
