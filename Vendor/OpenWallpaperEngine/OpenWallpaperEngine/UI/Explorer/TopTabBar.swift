//
//  TopTabBar.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

/// The main window's tabs, as a segmented control in the window toolbar.
struct TopTabBar: SubviewOfContentView {
    var viewModel: ContentViewModel

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Picker("Section", selection: Binding(
            get: { viewModel.navigation.topTabBarSelection },
            set: { tab in
                // A tab switch swaps the columns' contents at once; animating the Details
                // inspector in and out on every switch read as lag.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { viewModel.navigation.topTabBarSelection = tab }
            }
        )) {
            segment("Installed", systemImage: "square.and.arrow.down.fill").tag(0)
            // Tags are stored (`UpdateRelaunchState`), so Discover takes the next free one.
            segment("Discover", systemImage: "sparkles").tag(4)
            segment("Workshop", systemImage: "cloud.fill").tag(1)
            segment("Downloads", systemImage: "arrow.down.circle.fill").tag(2)
            segment("Playlists", systemImage: "rectangle.stack.fill").tag(3)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// A segment shows one text, so the icon goes inline to keep both.
    private func segment(_ title: LocalizedStringKey, systemImage: String) -> Text {
        Text("\(Image(systemName: systemImage)) \(Text(title))")
    }
}
