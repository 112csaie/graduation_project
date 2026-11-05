// PrivacyView.swift
//
// 隱私頁：selfIE 怎麼處理照片——哪些只在手機上、哪些會送到開發者的後端、哪些會問 Apple 地圖。
// 依「清單整理與回憶筆記」在哪裡做（AIRouter.onDevice：手機支援且使用者選在手機上）顯示不同的內容。

import SwiftUI

struct PrivacyView: View {
    private let onDevice = AIRouter.onDevice

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusCard

                section(title: "只在這支手機上", icon: "iphone", tint: Theme.accent, rows: [
                    ("photo.on.rectangle", "你/妳的照片", "只讀取，不會修改、移動或刪除原始照片和相簿"),
                    ("tag", "分類、tag、相簿", "照片特徵在手機上計算，資料存在手機裡"),
                    ("magnifyingglass", "智慧搜尋", "用手機上的 Apple Intelligence 看照片、寫場景描述"),
                    ("text.viewfinder", "照片上的文字", "文字辨識在手機上完成"),
                    ("person.crop.square", "自拍與人物照", "自拍沿用「照片」App 的自拍相簿；不偵測人臉，也不辨識是誰"),
                    ("book.pages", "筆記、想去清單、購物清單", "內容存在手機裡；刪除 App 時一起刪除"),
                ] + (onDevice ? [
                    ("list.bullet.rectangle", "清單整理、看圖描述", "從截圖整理店名、商品，在手機上完成"),
                    ("doc.text", "回憶筆記", "日期、地點、tag 整理成筆記，在手機上完成"),
                ] : []))

                section(title: "會送到開發者的後端", icon: "server.rack", tint: Theme.info, rows: [
                    ("bubble.left.and.text.bubble.right", "問 Agent", "你/妳打的問題、附上的那張照片，和相關的幾篇筆記"),
                ] + (onDevice ? [] : [
                    ("list.bullet.rectangle", "清單整理、看圖描述", "截圖上的文字；沒有文字時是那張照片"),
                    ("doc.text", "回憶筆記", "日期、地點、tag、場景描述這些文字（不送照片）"),
                ]), footnote: "後端是 selfIE 開發者架設的程式，會再交給它設定的 AI 模型回答。後端沒開時這些功能會暫停，其他功能照常。"
                    + (OnDeviceAI.isAvailable ? "可以在「設定 › 清單整理與回憶筆記」改回在手機上做。" : ""))

                section(title: "會問 Apple 地圖", icon: "map", tint: Theme.tile, rows: [
                    ("location", "照片的座標", "查回憶筆記裡去過的地方、想去清單在哪個縣市"),
                    ("mappin.and.ellipse", "店名和地址", "查想去清單的地點位置"),
                ], footnote: "和系統「照片」App 顯示地點的方式相同，不送照片。")

                section(title: "selfIE 不會", icon: "hand.raised", tint: Theme.card, rows: [
                    ("person.crop.circle.badge.xmark", "沒有帳號", "不用密碼，也沒有雲端帳號"),
                    ("icloud.slash", "不在背景上傳照片", "只有你/妳按下按鈕時，才送出上面列出的那些內容"),
                    ("location.slash", "不追蹤你/妳的位置", "不使用定位，只讀照片本身的拍攝地點"),
                ])
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("隱私")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Theme.onAccent)
                .frame(width: 56, height: 56)
                .background(Theme.accent)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("照片留在你/妳的手機")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(Theme.text)
                Text("selfIE 怎麼處理你/妳的照片")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.secondaryText)
            }
        }
        .padding(.top, 6)
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: onDevice ? "checkmark" : "info")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Theme.onAccent)
                .frame(width: 28, height: 28)
                .background(onDevice ? Theme.accent : Theme.info)
                .clipShape(Circle())
            Text(OnDeviceAI.statusText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(radius: 20)
    }

    private func section(title: String, icon: String, tint: Color,
                         rows: [(String, String, String)], footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.text)
                    .frame(width: 30, height: 30)
                    .background(tint)
                    .clipShape(Circle())
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.text)
            }
            .padding(.bottom, 6)
            ForEach(rows, id: \.1) { row in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: row.0)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.secondaryText)
                        .frame(width: 24)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.1)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.text)
                        Text(row.2)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 8)
            }
            if let footnote {
                Text(footnote)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)   // 每張卡片一樣寬
        .themeCard(radius: 22)
    }
}
