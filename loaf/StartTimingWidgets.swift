import SwiftUI

struct StartTimingWidget: View {
    @ObservedObject var service: StartTimerService
    let profileID: UUID
    let privateMode: Bool
    var stopwatch = false
    var compact = false
    var showsHeader = true
    @State private var customDuration = false
    @State private var minutes = "25"

    private func edit(_ change: (inout StartTimerService.Record, Date) -> Void) {
        service.edit(profileID, privateMode: privateMode, change)
    }
    var body: some View {
        let record = service.record(for: profileID)
        let running = stopwatch ? record.stopwatch.started != nil : record.countdown.deadline != nil
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds =
                stopwatch ? record.stopwatch.seconds(at: context.date) : record.countdown.seconds(at: context.date)
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                HStack(spacing: 6) {
                    if showsHeader {
                        Image(systemName: stopwatch ? "stopwatch" : "timer").font(.system(size: 13))
                        Text(stopwatch ? "stopwatch" : "timer").font(.system(size: 12, weight: .medium))
                    }
                    Spacer(minLength: 0)
                    if !stopwatch { durationMenu(record.countdown) }
                }.foregroundStyle(.secondary)
                Text(StartTimeDisplay.string(seconds, roundingUp: !stopwatch))
                    .font(.system(size: compact ? 32 : 40, weight: .light, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle(record.countdown.finished && !stopwatch ? Color.accentColor : Color.primary)
                    .accessibilityLabel(stopwatch ? "elapsed time" : "time remaining")
                if !stopwatch {
                    ProgressView(value: min(1, max(0, 1 - seconds / record.countdown.duration)))
                        .progressViewStyle(.linear).tint(.accentColor)
                        .accessibilityLabel("timer progress")
                }
                HStack(spacing: 8) {
                    Button {
                        edit { value, date in
                            if stopwatch {
                                value.stopwatch.toggle(at: date)
                            } else if value.countdown.deadline != nil {
                                value.countdown.pause(at: date)
                            } else {
                                value.countdown.start(at: date)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: running ? "pause.fill" : "play.fill").font(.system(size: 10))
                            Text(running ? "pause" : (!stopwatch && record.countdown.finished ? "again" : "start"))
                                .font(.system(size: 11, weight: .medium))
                        }.padding(.horizontal, 10).frame(height: 26)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel(running ? "pause" : "start")
                    Button {
                        edit { value, _ in
                            if stopwatch { value.stopwatch = StartStopwatch() } else { value.countdown.reset() }
                        }
                    } label: {
                        GolzheimIcon(icon: .reload, size: 13).frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("reset")
                    .accessibilityLabel("reset " + (stopwatch ? "stopwatch" : "timer"))
                    .disabled(
                        stopwatch
                            ? seconds == 0 && !running
                            : !running && !record.countdown.finished && seconds == record.countdown.duration)
                    Spacer(minLength: 0)
                    if !compact {
                        Text(
                            stopwatch
                                ? (running ? "running" : seconds > 0 ? "paused" : "ready")
                                : record.countdown.finished
                                    ? "time’s up"
                                    : running ? "running" : seconds < record.countdown.duration ? "paused" : "ready"
                        )
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if !stopwatch && record.countdown.finished && compact {
                    Text("time’s up").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                }
                if let error = service.saveError { Text(error).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
    }
    private func durationMenu(_ countdown: StartCountdown) -> some View {
        Menu {
            ForEach([5, 15, 25, 45, 60], id: \.self) { minutes in
                Button("\(minutes) minutes") { edit { value, _ in value.countdown.setDuration(Double(minutes * 60)) } }
            }
            Divider()
            Button("custom duration…") {
                minutes = String(Int(countdown.duration / 60))
                customDuration = true
            }
        } label: {
            Text("\(Int(countdown.duration / 60))m").font(.system(size: 11)).monospacedDigit()
        }.menuStyle(.borderlessButton).fixedSize().disabled(
            countdown.deadline != nil || countdown.remaining < countdown.duration && !countdown.finished
        )
        .help("timer duration").accessibilityLabel("timer duration")
        .popover(isPresented: $customDuration) {
            VStack(alignment: .leading, spacing: 12) {
                Text("timer duration").font(.system(size: 13, weight: .medium))
                HStack {
                    TextField("minutes", text: $minutes).frame(width: 64).onSubmit(setCustomDuration)
                        .accessibilityLabel("duration in minutes")
                    Text("minutes").foregroundStyle(.secondary)
                }
                HStack {
                    Text("1–1,440 minutes").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("set", action: setCustomDuration).disabled(customMinutes == nil)
                }
            }.padding(16).frame(width: 240)
        }
    }
    private var customMinutes: Int? {
        guard let value = Int(minutes.trimmingCharacters(in: .whitespacesAndNewlines)), (1...1440).contains(value)
        else { return nil }
        return value
    }
    private func setCustomDuration() {
        guard let value = customMinutes else { return }
        edit { record, _ in record.countdown.setDuration(Double(value * 60)) }
        customDuration = false
    }
}
