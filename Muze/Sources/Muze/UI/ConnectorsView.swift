import SwiftUI

/// Connectors — pull bookmarks & libraries from other services into your
/// memory. Imports are idempotent: run any connector again anytime and only
/// new items are added.
struct ConnectorsView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var center = ConnectorCenter()
    @State private var helpFor: ConnectorKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connectors")
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 30)
                Text("Pull your bookmarks and libraries into your memory. Imports are deduped — run them again anytime; only new items are added.")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.ink(0.5))
                    .padding(.bottom, 6)

                ForEach(ConnectorKind.allCases) { kind in
                    connectorCard(kind)
                }

                Text("Everything lands in chat (⌥Space), the graph, and resurfacing — ask \"what was that article I bookmarked about pricing?\"")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.ink(0.35))
                    .padding(.top, 4)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 30)
            .padding(.bottom, 40)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.gold)
    }

    private func connectorCard(_ kind: ConnectorKind) -> some View {
        let st = center.status[kind]
        return HStack(spacing: 14) {
            Image(systemName: kind.icon)
                .font(.system(size: 16))
                .foregroundStyle(Theme.gold)
                .frame(width: 38, height: 38)
                .background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.title)
                        .font(Theme.ui(13, .semibold))
                        .foregroundStyle(Theme.ink)
                    if let howTo = kind.howTo {
                        Button {
                            helpFor = kind
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ink(0.45))
                        }
                        .buttonStyle(.plain)
                        .help("How to get this")
                        .popover(
                            isPresented: Binding(
                                get: { helpFor == kind },
                                set: { if !$0 { helpFor = nil } }
                            ),
                            arrowEdge: .bottom
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(kind.needsFile ? "How to get the file" : "How this works")
                                    .font(Theme.ui(12, .semibold))
                                Text(howTo)
                                    .font(Theme.ui(12))
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(16)
                            .frame(width: 360)
                        }
                    }
                }
                Text(kind.blurb)
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.ink(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                if let st {
                    if st.running {
                        Text(st.phase)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.gold.opacity(0.85))
                    } else if let summary = st.summary {
                        Text(summary)
                            .font(Theme.ui(11))
                            .foregroundStyle(Theme.ink(0.65))
                    } else if let error = st.error {
                        Text(error)
                            .font(Theme.ui(11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer()

            if st?.running == true {
                ProgressView().controlSize(.small)
            } else {
                Button(st?.summary != nil ? "Re-import" : kind.buttonLabel) {
                    center.run(kind, settings: engine.settings)
                }
                .buttonStyle(PillButton(bg: Theme.gold, fg: .black))
            }
        }
        .tablet(padding: 14)
    }
}
