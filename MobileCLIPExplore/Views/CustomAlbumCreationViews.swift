// CustomAlbumCreationViews.swift
//
// 建立自訂相簿的流程：輸入名稱 → 預覽並挑選照片。從 DashboardView.swift 拆出來（內容不變）。

import SwiftUI
import Photos
import UIKit

struct CustomAlbumDraft: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let initialAssetIds: [String]
}

struct CustomAlbumNamePromptView: View {
    @Binding var albumName: String
    let errorMessage: String
    let onCancel: () -> Void
    let onSubmit: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Text("建立自訂相簿")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Theme.text)

                Text("輸入相簿名稱，我們會先幫你/妳選好相關的照片。")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.text.opacity(0.7))

                TextField("相簿名稱", text: $albumName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(Theme.text.opacity(0.12))
                    .cornerRadius(12)
                    .foregroundColor(Theme.text)
                    .focused($isFocused)
                    .onSubmit {
                        onSubmit()
                    }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.red.opacity(0.9))
                }

                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("取消")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.text.opacity(0.12))
                            .cornerRadius(12)
                    }

                    Button(action: onSubmit) {
                        Text("繼續")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.accent)
                            .cornerRadius(12)
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isFocused = true
            }
        }
    }
}

struct CustomAlbumDraftView: View {
    @Environment(\.dismiss) private var dismiss

    let draft: CustomAlbumDraft
    let onCreated: () -> Void

    @State private var selectedAssetIds: Set<String>
    @State private var selectedPreviewAssetId: IdentifiableString? = nil
    @State private var isCreating = false
    @State private var errorMessage = ""

    init(draft: CustomAlbumDraft, onCreated: @escaping () -> Void) {
        self.draft = draft
        self.onCreated = onCreated
        self._selectedAssetIds = State(initialValue: Set(draft.initialAssetIds))
    }

    private var orderedSelectedAssetIds: [String] {
        draft.initialAssetIds.filter { selectedAssetIds.contains($0) }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Theme.text)
                    }

                    Spacer()

                    VStack(spacing: 4) {
                        Text(draft.title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)

                        Text("已選 \(orderedSelectedAssetIds.count) 張")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.text.opacity(0.65))
                    }

                    Spacer()

                    Button(action: createAlbum) {
                        if isCreating {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: Theme.background))
                                .frame(width: 28, height: 28)
                        } else {
                            Text(orderedSelectedAssetIds.isEmpty ? "建立空相簿" : "建立")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(Theme.onAccent)
                        }
                    }
                    .disabled(isCreating)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.accent)
                    .cornerRadius(999)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)

                VStack(alignment: .leading, spacing: 12) {
                    Text("符合的照片已預先全部選取，建立前可以點照片取消或重新加入。")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.text.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Button(action: {
                        if selectedAssetIds.count == draft.initialAssetIds.count {
                            selectedAssetIds.removeAll()
                        } else {
                            selectedAssetIds = Set(draft.initialAssetIds)
                        }
                    }) {
                        Text(selectedAssetIds.count == draft.initialAssetIds.count ? "取消全選" : "全選")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Theme.text)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(Theme.text.opacity(0.15))
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 20)

                if draft.initialAssetIds.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 34))
                            .foregroundColor(Theme.text.opacity(0.45))
                        Text("找不到符合的照片")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Theme.text)
                        Text("仍然可以建立空相簿，或回上一步換個名稱。")
                            .font(.system(size: 14))
                            .multilineTextAlignment(.center)
                            .foregroundColor(Theme.text.opacity(0.6))
                            .padding(.horizontal, 28)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 15) {
                            ForEach(draft.initialAssetIds, id: \.self) { assetId in
                                Button(action: {
                                    toggleSelection(for: assetId)
                                }) {
                                    ZStack(alignment: .topTrailing) {
                                        PhotoThumbnailView(assetId: assetId)
                                            .frame(height: 170)
                                            .cornerRadius(14)
                                            .clipped()
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 14)
                                                    .fill(Color.black.opacity(selectedAssetIds.contains(assetId) ? 0.04 : 0.45))
                                            }

                                        Image(systemName: selectedAssetIds.contains(assetId) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 24, weight: .semibold))
                                            .foregroundColor(selectedAssetIds.contains(assetId) ? Theme.text : Theme.text.opacity(0.75))
                                            .padding(10)
                                    }
                                }
                                .contextMenu {
                                    Button(action: {
                                        selectedPreviewAssetId = IdentifiableString(id: assetId)
                                    }) {
                                        Label("Preview", systemImage: "eye")
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .sheet(item: $selectedPreviewAssetId) { assetItem in
            PhotoDetailModal(assetId: assetItem.id)
        }
        .alert("無法建立相簿", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { !errorMessage.isEmpty },
            set: { isPresented in
                if !isPresented {
                    errorMessage = ""
                }
            }
        )
    }

    private func toggleSelection(for assetId: String) {
        if selectedAssetIds.contains(assetId) {
            selectedAssetIds.remove(assetId)
        } else {
            selectedAssetIds.insert(assetId)
        }
    }

    private func createAlbum() {
        guard !DatabaseManager.shared.customAlbumExists(named: draft.title) else {
            errorMessage = "An album named \"\(draft.title)\" already exists."
            return
        }

        isCreating = true
        let albumId = DatabaseManager.shared.createCustomAlbum(title: draft.title, assetIds: orderedSelectedAssetIds)
        isCreating = false

        guard albumId != nil else {
            errorMessage = "目前無法建立相簿，請稍後再試。"
            return
        }

        onCreated()
        dismiss()
    }
}
