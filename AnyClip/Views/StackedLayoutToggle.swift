//
//  StackedLayoutToggle.swift
//  AnyClip
//
//  The switch for the two-speaker stacked layout. The first time it's turned
//  on it explains what the layout needs from the video and asks the user to
//  confirm; after that it's an ordinary switch.
//

import SwiftUI

struct StackedLayoutToggle<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder var label: Label
    @State private var explaining = false

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { wanted in
            switch StackedLayoutIntro.request(wanted) {
            case .apply(let value): isOn = value
            case .explain: explaining = true
            }
        })) {
            label
        }
        .sheet(isPresented: $explaining) {
            StackedLayoutIntroSheet { isOn = true }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugDriver.showStackIntro)) { _ in explaining = true }
        #endif
    }
}

struct StackedLayoutIntroSheet: View {
    var onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "rectangle.split.1x2")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Two-Speaker Stacked Layout")
                        .font(.title3.weight(.semibold))
                    Text("Create vertical videos with two speakers displayed one above the other.")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("This feature works best with footage where both speakers remain visible in a consistent camera shot. Videos that frequently switch between speakers or camera angles may produce different layouts throughout the clip.")
                Text("When only one speaker is on screen, AnyClip shows that part full-frame.")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $confirmed) {
                Text("My video contains both speakers in a consistent shot, or I understand that results may vary when the camera switches between speakers.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    StackedLayoutIntro.confirm()
                    onContinue()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!confirmed)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
