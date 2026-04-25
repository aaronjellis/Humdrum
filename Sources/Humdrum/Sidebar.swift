import SwiftUI
import AppKit
import HumdrumCore

struct Sidebar: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var manager: TranscriptionManager
    @Environment(\.openWindow)   private var openWindow
    @Environment(\.openSettings) private var openSettings

    let recordingInProgress: Bool

    @State private var searchQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            startRecordingButton
            searchField
            listHeader
            sessionList
            Spacer(minLength: 0)
            versionBlock
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.sidebar)
    }

    // MARK: Search
    //
    // Simple case-insensitive substring match across title + transcript
    // text. Kept local to the sidebar — the query doesn't need to persist
    // across launches, and filtering in-memory is fine at the scale of
    // sessions a single user accumulates. If session count ever grows
    // into the thousands we'd want indexed search, but that's a problem
    // for future-us.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.textTertiary)
            TextField("Search sessions", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.textPrimary)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 0.5)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var filteredSessions: [TranscriptSession] {
        let q = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !q.isEmpty else { return store.sessions }

        // Score each session and rank by relevance. Title matches use
        // the full fuzzy matcher (typos, subsequences, word boundaries);
        // transcript matches are plain substring only — fuzzy across a
        // multi-thousand-word transcript is both expensive and noisy.
        // Title score is weighted 3× so "budget" always surfaces a
        // session titled "Budget review" above one that merely mentions
        // the word somewhere deep in the body.
        struct Hit { let session: TranscriptSession; let score: Int }
        var hits: [Hit] = []
        for session in store.sessions {
            let titleScore = FuzzyMatcher.score(
                query: q,
                in: session.displayTitle.lowercased()
            )
            let transcriptMatch = session.transcriptText
                .range(of: q, options: .caseInsensitive) != nil

            if let ts = titleScore {
                hits.append(Hit(session: session, score: ts * 3))
            } else if transcriptMatch {
                hits.append(Hit(session: session, score: 50))
            }
        }
        return hits
            .sorted {
                $0.score != $1.score
                    ? $0.score > $1.score
                    : $0.session.createdAt > $1.session.createdAt
            }
            .map(\.session)
    }

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Brand block

    private var brand: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                AppTheme.accent,
                                AppTheme.accent.opacity(0.55)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 42, height: 42)
                    .shadow(color: AppTheme.accentGlow, radius: 10, x: 0, y: 0)
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Humdrum")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Local transcripts")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    // MARK: Start Recording CTA

    private var startRecordingButton: some View {
        let busy = manager.isBusy
        return Button(action: openSetup) {
            HStack(spacing: 10) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.black.opacity(0.7))
                } else {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                }
                Text(busy ? (manager.busyReason ?? "Working…") : "Start Recording")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if !busy {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.55)
                }
            }
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.accent, AppTheme.accentDim],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
            .shadow(color: AppTheme.accentGlow, radius: 10, x: 0, y: 0)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.55 : 1)
        .padding(.horizontal, 12)
        .padding(.bottom, 18)
        .help(busy
              ? "Wait for the current recording / processing to finish"
              : "Opens the pre-recording setup window")
    }

    private func openSetup() {
        openWindow(id: WindowID.setup)
    }

    // MARK: Section header

    private var listHeader: some View {
        Text("Recent")
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(AppTheme.textTertiary)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
    }

    // MARK: Session list

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                if store.sessions.isEmpty {
                    Text("No sessions yet.\nStart a recording on the right.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.textTertiary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .fixedSize(horizontal: false, vertical: true)
                } else if filteredSessions.isEmpty && isSearching {
                    Text("No sessions match “\(searchQuery)”.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.textTertiary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(filteredSessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: appState.selection == .session(session.id),
                        onSelect: { appState.selection = .session(session.id) },
                        onRename: { newTitle in
                            store.rename(session, to: newTitle)
                        },
                        onDelete: {
                            let wasSelected = appState.selection == .session(session.id)
                            store.delete(session)
                            if wasSelected { appState.selection = .newSession }
                        }
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }

    // MARK: Footer

    private var versionBlock: some View {
        HStack(spacing: 8) {
            Button(action: openSettingsWindow) {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                    Text("Settings")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("Open Settings (⌘,)")

            Spacer()

            Text("v0.1.0")
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}

// MARK: - Session row

private struct SessionRow: View {
    let session: TranscriptSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var draftTitle = ""
    @FocusState private var editingFocused: Bool

    var body: some View {
        Button(action: {
            // When editing, the TextField owns clicks — don't let the
            // enclosing Button hijack focus and kick the user out of
            // rename mid-keystroke.
            if !isEditing { onSelect() }
        }) {
            HStack(spacing: 0) {
                // Emerald left-edge on the active row
                Rectangle()
                    .fill(isSelected ? AppTheme.accent : Color.clear)
                    .frame(width: 2)
                    .cornerRadius(1)

                VStack(alignment: .leading, spacing: 3) {
                    if isEditing {
                        TextField("Name", text: $draftTitle)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .focused($editingFocused)
                            .onSubmit(commitRename)
                            .onExitCommand(perform: cancelRename)
                            // Commit on focus loss too (click elsewhere
                            // without pressing Return) — matches Finder's
                            // rename behavior. onSubmit + cancel both
                            // already flip isEditing, so this branch
                            // only runs when focus is lost passively.
                            .onChange(of: editingFocused) { _, focused in
                                if !focused && isEditing { commitRename() }
                            }
                    } else {
                        Text(session.displayTitle)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Text(metadataLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(1)
                }
                .padding(.leading, 10)
                .padding(.vertical, 8)
                .padding(.trailing, 8)

                Spacer(minLength: 4)
            }
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected
                          ? AppTheme.accentSoft
                          : (isHovering ? Color.white.opacity(0.03) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? AppTheme.accentBorder : Color.clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename", action: beginRename)
            Button("Delete Session", role: .destructive, action: onDelete)
        }
    }

    // MARK: Rename lifecycle
    //
    // Enter on a context-menu "Rename" or a programmatic call. We seed
    // the TextField with the stored title (not displayTitle) so auto-
    // generated-from-transcript titles appear as placeholder-ish text
    // the user can overwrite in one keystroke.
    private func beginRename() {
        draftTitle = session.title
        isEditing = true
        // Focus has to be set after the TextField exists — a one-tick
        // delay is enough for SwiftUI to materialize it.
        DispatchQueue.main.async { editingFocused = true }
    }

    private func commitRename() {
        onRename(draftTitle)
        isEditing = false
    }

    private func cancelRename() {
        isEditing = false
    }

    private var metadataLine: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        let date = f.string(from: session.createdAt)
        let dur = session.durationSeconds
        return "\(date) · \(String(format: "%d:%02d", dur / 60, dur % 60))"
    }
}
