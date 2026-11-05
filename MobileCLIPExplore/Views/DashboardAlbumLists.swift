// DashboardAlbumLists.swift
//
// 首頁「查看全部」的相簿列表頁。從 DashboardView.swift 拆出來（內容不變）。

import SwiftUI
import Photos
import UIKit

struct GroupAlbumListView: View {
    let groupTitle: String
    let subAlbums: [CategoryAlbumSummary]
    @ObservedObject var syncVM: PhotoSyncViewModel

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(groupTitle.capitalized)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(Theme.text)
                        .padding(.top, 12)

                    Text("\(subAlbums.count) 個相簿")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.text.opacity(0.6))

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(subAlbums) { album in
                            NavigationLink(
                                destination: CategoryDetailView(
                                    categoryTitle: album.title,
                                    syncVM: syncVM
                                )
                            ) {
                                CategoryAlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }
}

struct MetadataAlbumListView: View {
    let title: String
    let albums: [MetadataAlbumSummary]
    @ObservedObject var syncVM: PhotoSyncViewModel

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(Theme.text)
                        .padding(.top, 12)

                    Text("\(albums.count) 趟旅行")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.text.opacity(0.6))

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(albums) { album in
                            NavigationLink(
                                destination: CategoryDetailView(metadataAlbum: album, syncVM: syncVM)
                            ) {
                                MetadataAlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }
}

struct CustomAlbumListView: View {
    let customAlbums: [CustomAlbumSummary]
    @ObservedObject var syncVM: PhotoSyncViewModel
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("我的相簿")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(Theme.text)
                        .padding(.top, 12)

                    Text("\(customAlbums.count) 個相簿")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.text.opacity(0.6))

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(customAlbums) { album in
                            NavigationLink(
                                destination: CategoryDetailView(customAlbum: album, syncVM: syncVM)
                            ) {
                                CustomAlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }
}
