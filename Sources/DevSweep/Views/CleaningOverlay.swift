import DevSweepCore
import SwiftUI

/// The panel shown while something is being cleaned: a ring filling up, a counter ticking,
/// items sliding into the list as they go, then a little celebration.
struct CleaningOverlay: View {
    @Environment(AppModel.self) private var model
    let session: CleaningSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.38))
                .ignoresSafeArea()
                .onTapGesture { if session.isFinished { model.dismissCleaning() } }

            VStack(spacing: 16) {
                ZStack {
                    ProgressRing(progress: session.isFinished ? 1 : session.progress, lineWidth: 11, spinning: !session.isFinished)
                        .frame(width: 132, height: 132)
                    if session.isFinished {
                        Image(systemName: session.kept > 0 && session.freed == 0 ? "exclamationmark" : "checkmark")
                            .font(.system(size: 50, weight: .bold, design: .rounded))
                            .foregroundStyle(Brand.gradient)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    } else {
                        TimelineView(.animation(minimumInterval: decorativeFrameInterval, paused: reduceMotion)) { context in
                            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                            Image(systemName: "bubbles.and.sparkles.fill")
                                .font(.system(size: 40, weight: .medium))
                                .foregroundStyle(Brand.gradient)
                                .offset(y: sin(t * 4.2) * 4)
                                .rotationEffect(.degrees(sin(t * 2.6) * 9))
                                .scaleEffect(1 + 0.05 * sin(t * 8.4))
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.top, 4)

                VStack(spacing: 4) {
                    Text(session.isFinished ? (session.movedToTrash ? "Moved to the Trash" : "Freed") : session.title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(Format.bytes(session.freed))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(session.freed)))
                    if !session.isFinished {
                        Text("\(session.done) of \(session.total)")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(session.done)))
                    }
                }

                // What's being removed right now; each name pushes the previous one out.
                ZStack {
                    if !session.isFinished, !session.current.isEmpty {
                        Text(session.current)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .id(session.current)
                            .transition(.push(from: .bottom))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: session.isFinished ? 0 : 18)
                .clipped()

                // The last few items, newest sliding in at the top and the oldest dropping out
                // of the bottom of a fixed-height window, so rows never overlap.
                VStack(spacing: 0) {
                    ForEach(session.recent.prefix(4)) { step in
                        HStack(spacing: 8) {
                            Image(systemName: step.removed ? "checkmark.circle.fill" : "minus.circle.fill")
                                .foregroundStyle(step.removed ? Color.green : Color.secondary)
                            Text(step.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Format.bytes(step.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .frame(height: 22)
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .move(edge: .bottom).combined(with: .opacity)))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88, alignment: .top)
                .clipped()
                .mask(LinearGradient(colors: [.black, .black, .black.opacity(0.2)], startPoint: .top, endPoint: .bottom))
                .padding(.horizontal, 4)

                if session.isFinished {
                    VStack(spacing: 12) {
                        if let detail = session.detail {
                            Text(detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button("Done") { model.dismissCleaning() }
                            .buttonStyle(PrimaryPillStyle(theme: .smartScan, large: true))
                            .keyboardShortcut(.defaultAction)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(26)
            .frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .overlay {
                if let finishedAt = session.finishedAt, session.freed > 0 {
                    ConfettiBurst(start: finishedAt)
                        .frame(width: 600, height: 700)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
        .task(id: session.finishedAt) {
            // Celebrate, then get out of the way.
            guard session.isFinished else { return }
            try? await Task.sleep(for: .seconds(session.detail == nil ? 3.5 : 7))
            if model.cleaning?.id == session.id { model.dismissCleaning() }
        }
    }
}

/// A compact version for the menu bar panel.
struct MiniCleaningProgress: View {
    let session: CleaningSession

    var body: some View {
        HStack(spacing: 12) {
            ProgressRing(progress: session.isFinished ? 1 : session.progress, lineWidth: 5, spinning: !session.isFinished)
                .frame(width: 34, height: 34)
                .overlay {
                    if session.isFinished {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Brand.gradient)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.isFinished ? "Done" : session.title).font(.callout.weight(.medium))
                Text(Format.bytes(session.freed))
                    .font(.title3.weight(.bold)).monospacedDigit()
                    .contentTransition(.numericText(value: Double(session.freed)))
            }
        }
    }
}
