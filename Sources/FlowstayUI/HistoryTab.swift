import FlowstayCore
import SwiftUI

struct HistoryTab: View {
    @ObservedObject var appState: AppState
    @State private var records: [TranscriptionRecord] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var showingSettings = false
    @State private var showingClearConfirmation = false

    private var filteredRecords: [TranscriptionRecord] {
        if searchText.isEmpty {
            return records
        }
        let query = searchText.lowercased()
        return records.filter { record in
            record.rawText.lowercased().contains(query) ||
                record.processedText.lowercased().contains(query) ||
                (record.appName?.lowercased().contains(query) ?? false) ||
                (record.personaName?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            // Search and controls
            searchBar
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider()

            // Content
            if isLoading {
                loadingView
            } else if records.isEmpty {
                emptyStateView
            } else if filteredRecords.isEmpty {
                noResultsView
            } else {
                recordsList
            }
        }
        .task {
            await loadRecords()
        }
        .sheet(isPresented: $showingSettings) {
            historySettingsSheet
        }
        .alert("Clear All History", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                Task {
                    _ = await TranscriptionHistoryStore.shared.deleteAll()
                    await loadRecords()
                }
            }
        } message: {
            Text("This will permanently delete all transcription history. This action cannot be undone.")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("History")
                    .font(.albertSans(28, weight: .bold))
                Text("View and search your transcription history")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            // Record count
            if !isLoading {
                Text("\(records.count) transcriptions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcriptions...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Settings button
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gear")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("History settings")
        }
    }

    // MARK: - Content Views

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading history...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No transcription history")
                .font(.headline)
            Text("Your transcriptions will appear here after you record them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noResultsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No results found")
                .font(.headline)
            Text("Try a different search term.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var recordsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(filteredRecords) { record in
                    HistoryRecordCard(record: record) {
                        Task {
                            await TranscriptionHistoryStore.shared.deleteIgnoringErrors(record.id)
                            await loadRecords()
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Settings Sheet

    private var historySettingsSheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("History Settings")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    showingSettings = false
                }
            }
            .padding()

            Divider()

            Form {
                Section("Retention") {
                    Picker("Keep history for", selection: $appState.historyRetentionDays) {
                        Text("Unlimited").tag(0)
                        Text("1 day").tag(1)
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    .pickerStyle(.menu)

                    if appState.historyRetentionDays > 0 {
                        Text("Transcriptions older than \(appState.historyRetentionDays) days will be automatically deleted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Transcriptions will be kept until you manually delete them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Manage") {
                    Button(role: .destructive) {
                        showingClearConfirmation = true
                        showingSettings = false
                    } label: {
                        Label("Clear All History", systemImage: "trash")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 400, height: 300)
    }

    // MARK: - Actions

    private func loadRecords() async {
        isLoading = true
        records = await TranscriptionHistoryStore.shared.getAllOrEmpty()
        isLoading = false
    }
}

// MARK: - History Record Card

struct HistoryRecordCard: View {
    let record: TranscriptionRecord
    let onDelete: () -> Void

    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack {
                // Timestamp and metadata
                HStack(spacing: 8) {
                    Text(record.formattedTimestamp)
                        .font(.subheadline.weight(.medium))

                    if let appName = record.appName {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(appName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(record.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Delete button
                Button {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete this transcription")
            }

            // Text comparison
            HStack(alignment: .top, spacing: 12) {
                // Original text
                textBox(
                    title: "Original",
                    text: record.rawText,
                    accentColor: .secondary
                )

                // Processed text
                textBox(
                    title: record.wasProcessed ? "Processed (\(record.personaName ?? "Persona"))" : "Output",
                    text: record.processedText,
                    accentColor: record.wasProcessed ? .blue : .secondary
                )
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .alert("Delete Transcription", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("Are you sure you want to delete this transcription? This action cannot be undone.")
        }
    }

    private func textBox(title: String, text: String, accentColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(accentColor)

            Text(text)
                .font(.callout)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Copy button
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
