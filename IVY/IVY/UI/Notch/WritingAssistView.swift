import AppKit
import IVYCore
import SwiftUI

/// Shares IVY's notch silhouette and dark typography; the source app keeps its selection.
struct WritingAssistView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var service: WritingAssistService

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                IVYMark(active: service.isWorking).frame(width: 16, height: 16)
                Spacer()
                Button { model.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }.buttonStyle(.plain).help("Close writing assistant")
            }
            .padding(.horizontal, NotchLayout.openTopRadius + 12)
            .frame(height: model.geometry.topBandHeight)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Writing", systemImage: "pencil.line").font(.headline)
                        Spacer()
                        Text(service.sourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !service.original.isEmpty {
                        HStack(spacing: 6) {
                            ForEach([WritingAction.improve, .rephrase, .shorten, .translate]) { action in
                                Button(action.title) {
                                    service.action = action; service.generate()
                                }
                                .buttonStyle(.bordered)
                                .tint(service.action == action ? Color.green : Color.gray)
                                .disabled(service.isWorking || service.isApplying)
                            }
                            Menu {
                                ForEach([WritingAction.professional, .friendly]) { action in
                                    Button(action.title) { service.action = action; service.generate() }
                                }
                            } label: { Image(systemName: "ellipsis") }
                            .disabled(service.isWorking || service.isApplying)
                        }.controlSize(.small)
                        if service.suggestion.isEmpty && !service.isWorking {
                            Text(service.original).foregroundStyle(.white.opacity(0.8)).lineLimit(6)
                            Text("Choose an action to preview a rewrite. Your field changes only when you accept.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            DisclosureGroup("Original") {
                                Text(service.original).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }.font(.caption)
                            Text(service.suggestion.isEmpty ? "Preparing your rewrite…" : service.suggestion)
                                .font(.system(size: 15)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                            HStack {
                                if service.isApplying {
                                    ProgressView().controlSize(.small)
                                    Text("Replacing selected text…").font(.caption)
                                } else if service.isWorking {
                                    ProgressView().controlSize(.small)
                                    Text("Writing with " + service.activeModelLabel).font(.caption).lineLimit(1)
                                    Spacer()
                                    Button("Stop") { service.cancel() }
                                } else if service.applied {
                                    Label("Replaced in your text field", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green).font(.callout)
                                } else {
                                    Button("Accept") { service.accept() }.buttonStyle(.borderedProminent).tint(.green)
                                        .disabled(!service.readyToAccept || !service.error.isEmpty)
                                    Button("Revise") { service.generate() }
                                    Spacer()
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(service.suggestion, forType: .string)
                                    } label: { Image(systemName: "doc.on.doc") }
                                    .help("Copy suggestion")
                                }
                            }.controlSize(.small)
                        }
                    }
                    if !service.error.isEmpty {
                        Text(service.error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    Text(service.activeModelLabel + (service.sendsToCloud ? " · Selection sent when you choose an action" : " · On this Mac"))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 16)
            }.frame(height: 320)
        }.onAppear { model.assistantBodyHeight = 320 }
    }
}
