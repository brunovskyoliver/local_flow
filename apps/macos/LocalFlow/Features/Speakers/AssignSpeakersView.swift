import SwiftUI

/// The Assign speakers dialog (contracts/ui.md), laid out like Wispr's: a card over a
/// dimmed note, one block per voice with its quotes and a name field, Cancel and Save
/// names at the bottom. Cancel, Escape, the close button and the backdrop discard the
/// drafts; Save names commits them together and closes.
struct AssignSpeakersView: View {
  static let cardWidth: CGFloat = 560
  static let fieldHeight: CGFloat = 46

  @State var model: AssignSpeakersModel
  /// Called after a successful save, before the dialog closes. Return triggers Save
  /// names, Escape triggers Cancel.
  let saved: () -> Void
  /// Called after a merge or unmerge, which apply immediately (FR-025).
  var structureChanged: () -> Void = {}
  /// Removes the dialog; the owner drops the model with it.
  var close: () -> Void = {}
  @FocusState private var focused: UUID?

  var body: some View {
    ZStack {
      Color.black.opacity(0.28)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { close() }
        .accessibilityHidden(true)
      card
        .frame(width: Self.cardWidth)
        .background(SottoPalette.surface, in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .overlay {
          RoundedRectangle(cornerRadius: 18).strokeBorder(NotetakerStyle.rule, lineWidth: 1)
        }
    }
    .foregroundStyle(SottoPalette.ink)
    .accessibilityIdentifier("meeting.speakers.assign")
    .onExitCommand { close() }
    .task {
      await model.load()
      focused = model.sections.first?.id
    }
    .onChange(of: model.structureRevision) { _, _ in structureChanged() }
    .task(id: focusedDraft) {
      guard let focused else { return }
      await model.refreshSuggestions(for: focused)
    }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Assign speakers").font(.system(size: 30, weight: .regular, design: .serif))
        Text("Name each voice and we'll relabel the whole transcript.")
          .font(.system(size: 14)).foregroundStyle(SottoPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 8)
      .overlay(alignment: .topTrailing) {
        Button(action: close) {
          Image(systemName: "xmark").font(.system(size: 15, weight: .medium))
            .frame(width: 30, height: 30).contentShape(.rect)
        }
        .buttonStyle(.plain).padding(.top, 22).padding(.trailing, 22)
        .accessibilityLabel("Close")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          ForEach(model.reviews) { review in reviewRow(review) }
          if model.isLoading, model.sections.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(20)
          } else if model.sections.isEmpty {
            Text("There are no speakers to name.").font(.system(size: 14))
              .foregroundStyle(SottoPalette.muted)
          }
          ForEach(Array(model.sections.enumerated()), id: \.element.id) { index, section in
            sectionView(section, position: index + 1)
              // An open suggestion list floats over the block below it.
              .zIndex(focused == section.id ? 1 : 0)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 28)
      }
      .scrollIndicators(.hidden)
      .hideScrollers()
      .frame(minHeight: 160, maxHeight: 480)
      NotetakerStyle.rule.frame(height: 1)
      HStack(spacing: 10) {
        if let notice = model.notice {
          Text(notice).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2)
        }
        Spacer()
        Button("Cancel", action: close)
          .buttonStyle(AssignSpeakersButtonStyle(prominent: false))
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("meeting.speakers.cancel")
        Button(model.enrollmentCompleted ? "Done" : "Save names", action: save)
          .buttonStyle(AssignSpeakersButtonStyle(prominent: true))
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canSave && !model.enrollmentCompleted)
          .accessibilityIdentifier("meeting.speakers.save")
      }
      .padding(.horizontal, 28).padding(.vertical, 18)
    }
  }

  private func save() {
    if model.enrollmentCompleted {
      saved()
      close()
      return
    }
    Task {
      let closes = await model.save()
      saved()
      if closes { close() }
    }
  }

  /// Re-queries suggestions whenever the focused field or its text changes.
  private var focusedDraft: String {
    guard let focused else { return "" }
    return focused.uuidString + (model.sections.first { $0.id == focused }?.draft ?? "")
  }

  private func reviewRow(_ review: ReviewNotice) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
      Text(review.text).font(.system(size: 13))
      Spacer()
      Button("Dismiss") { Task { await model.dismissReview(review.id) } }
        .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
        .foregroundStyle(SottoPalette.muted)
        .accessibilityLabel("Dismiss notice: \(review.name)")
    }
    .padding(12)
    .background(SottoPalette.canvas, in: .rect(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("meeting.speakers.review")
  }

  /// `position` is the section's 1-based place in the dialog; ordinals repeat across sources.
  private func sectionView(_ section: AssignSpeakersModel.Section, position: Int) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 9) {
        Circle().fill(SpeakerPalette.color(section.speaker.colorIndex)).frame(width: 10, height: 10)
        Text(section.anonymousLabel.uppercased())
          .font(.system(size: 12, weight: .semibold)).tracking(1.4)
        if section.speaker.isYou {
          Text("This Mac's microphone").font(.system(size: 12))
            .foregroundStyle(SottoPalette.muted)
        }
      }
      .accessibilityElement(children: .contain)
      ForEach(section.includes) { member in
        HStack(spacing: 8) {
          Text("Includes \(member.anonymousLabel)").font(.system(size: 13))
            .foregroundStyle(SottoPalette.muted)
          Button("Undo merge") { Task { await model.unmerge(member.id) } }
            .buttonStyle(.plain).font(.system(size: 13, weight: .medium))
            .accessibilityLabel("Undo merge of \(member.anonymousLabel)")
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(section.speaker.quotes.enumerated()), id: \.offset) { _, quote in
          HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1).fill(NotetakerStyle.rule).frame(width: 2)
            Text("\u{201C}\(quote)\u{201D}").font(.system(size: 15)).lineSpacing(4)
              .foregroundStyle(SottoPalette.ink.opacity(0.85)).lineLimit(3)
              .fixedSize(horizontal: false, vertical: true)
          }
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      nameField(section, position: position)
      if let block = model.identityBlock(for: section.id) {
        identityBlock(block, section: section)
      }
      if let error = section.error {
        Text(error).font(.system(size: 12)).foregroundStyle(.red)
      } else if let other = model.duplicate(of: section.id) {
        HStack(spacing: 8) {
          Text("Same name as \(other.anonymousLabel).").font(.system(size: 12))
            .foregroundStyle(SottoPalette.muted)
          Button("Merge") { Task { await model.merge(section.id, into: other.id) } }
            .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            .accessibilityLabel("Merge into \(other.anonymousLabel)")
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func nameField(_ section: AssignSpeakersModel.Section, position: Int) -> some View {
    let active = focused == section.id
    return TextField(
      "Type a name",
      text: Binding(get: { section.draft }, set: { model.setDraft($0, for: section.id) })
    )
    .textFieldStyle(.plain)
    .font(.system(size: 15))
    .padding(.horizontal, 16)
    .frame(height: Self.fieldHeight)
    .background(SottoPalette.surface, in: .rect(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(active ? SottoPalette.ink : NotetakerStyle.rule, lineWidth: active ? 2 : 1)
    }
    .animation(.easeOut(duration: 0.12), value: active)
    .focused($focused, equals: section.id)
    .onSubmit(save)
    .accessibilityLabel("Name for \(section.anonymousLabel)")
    .accessibilityIdentifier("meeting.speakers.name.\(position)")
    .overlay(alignment: .topLeading) {
      if active, !model.suggestions.isEmpty {
        suggestionList(for: section.id).offset(y: Self.fieldHeight + 6)
      }
    }
  }

  // MARK: Identity (Feature 010, contracts/ui.md)

  @ViewBuilder
  private func identityBlock(
    _ block: AssignSpeakersModel.IdentityBlock, section: AssignSpeakersModel.Section
  )
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      if let local = block.localState {
        switch local {
        case .offer:
          if section.identityAction == .rememberLocal {
            Text("Your voice will be remembered from this Mac's microphone.")
              .font(.system(size: 12)).foregroundStyle(SottoPalette.muted)
          } else {
            Button("Remember my voice") { model.setIdentityAction(.rememberLocal, for: section.id) }
              .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
              .accessibilityIdentifier("identity.rememberLocal")
          }
        case .remembered:
          Text("Your voice is remembered").font(.system(size: 12))
            .foregroundStyle(SottoPalette.muted)
        }
      } else {
        HStack(spacing: 8) {
          Text(block.matchState).font(.system(size: 12, weight: .medium))
            .foregroundStyle(block.needsChoice ? .orange : SottoPalette.muted)
            .accessibilityIdentifier("identity.matchState")
          if !block.picker.isEmpty, !block.needsChoice {
            pickerMenu(block.picker, section: section, title: "Known speakers…")
              .accessibilityIdentifier("identity.picker")
          }
        }
        if block.needsChoice {
          mergedChoice(block, section: section)
        } else if block.showsSuggestionActions {
          suggestionActions(block, section: section)
        }
        if let duplicate = block.duplicateOf {
          duplicateChoice(duplicate, section: section)
        } else if block.showsRemember {
          rememberRow(section)
        }
        if block.showsAlsoRemember {
          Toggle(
            "Also remember this voice sample",
            isOn: Binding(
              get: { section.alsoRemember },
              set: { model.setAlsoRemember($0, for: section.id) })
          )
          .toggleStyle(.checkbox).font(.system(size: 12))
          .accessibilityIdentifier("identity.alsoRemember")
        }
      }
      if let result = section.enrollmentResult {
        Text(result).font(.system(size: 12)).foregroundStyle(SottoPalette.muted)
          .accessibilityIdentifier("identity.enrollmentResult")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("identity.block")
  }

  private func rememberRow(_ section: AssignSpeakersModel.Section) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Text(AssignSpeakersModel.rememberQuestion).font(.system(size: 13, weight: .medium))
        Button("Remember") { model.setIdentityAction(.remember, for: section.id) }
          .buttonStyle(AssignSpeakersButtonStyle(prominent: section.identityAction == .remember))
          .accessibilityIdentifier("identity.remember")
        Button("Not now") { model.setIdentityAction(.notNow, for: section.id) }
          .buttonStyle(AssignSpeakersButtonStyle(prominent: false))
          .opacity(section.identityAction == .notNow ? 1 : 0.7)
          .accessibilityIdentifier("identity.notNow")
      }
      Text(AssignSpeakersModel.rememberSentence).font(.system(size: 12))
        .foregroundStyle(SottoPalette.muted).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("identity.rememberSentence")
    }
  }

  private func duplicateChoice(_ known: KnownSpeakerRow, section: AssignSpeakersModel.Section)
    -> some View
  {
    HStack(spacing: 10) {
      Text("Is this \(known.name) you already remember?").font(.system(size: 13, weight: .medium))
      Button("Same person") {
        model.setIdentityAction(.rememberSamePerson(known.id), for: section.id)
      }
      .buttonStyle(AssignSpeakersButtonStyle(prominent: true))
      .accessibilityIdentifier("identity.samePerson")
      Button("Someone new") { model.setIdentityAction(.rememberNew, for: section.id) }
        .buttonStyle(AssignSpeakersButtonStyle(prominent: false))
        .accessibilityIdentifier("identity.someoneNew")
    }
  }

  private func suggestionActions(
    _ block: AssignSpeakersModel.IdentityBlock, section: AssignSpeakersModel.Section
  ) -> some View {
    HStack(spacing: 10) {
      Button("Confirm") { model.setIdentityAction(.confirm, for: section.id) }
        .buttonStyle(AssignSpeakersButtonStyle(prominent: section.identityAction == .confirm))
        .accessibilityIdentifier("identity.confirm")
      pickerMenu(block.picker, section: section, title: "Choose another…")
        .accessibilityIdentifier("identity.chooseAnother")
      Button("Keep Unknown") { model.setIdentityAction(.keepUnknown, for: section.id) }
        .buttonStyle(AssignSpeakersButtonStyle(prominent: section.identityAction == .keepUnknown))
        .accessibilityIdentifier("identity.keepUnknown")
    }
  }

  private func mergedChoice(
    _ block: AssignSpeakersModel.IdentityBlock, section: AssignSpeakersModel.Section
  ) -> some View {
    HStack(spacing: 10) {
      Menu("Choose a known speaker…") {
        ForEach(block.picker) { known in
          Button(known.name) {
            model.setIdentityAction(.resolveMerged(.knownSpeaker(known.id)), for: section.id)
          }
        }
      }
      .menuStyle(.borderlessButton).fixedSize()
      .accessibilityIdentifier("identity.mergedPicker")
      Button("Keep Unknown") {
        model.setIdentityAction(.resolveMerged(.keepUnknown), for: section.id)
      }
      .buttonStyle(AssignSpeakersButtonStyle(prominent: false))
      .accessibilityIdentifier("identity.mergedKeepUnknown")
    }
  }

  /// The known-speaker menu: name, sample count and the re-enrollment tag; never scores.
  private func pickerMenu(
    _ known: [KnownSpeakerRow], section: AssignSpeakersModel.Section, title: String
  ) -> some View {
    Menu(title) {
      ForEach(known) { row in
        Button(pickerTitle(row)) { model.pickKnownSpeaker(row.id, for: section.id) }
      }
    }
    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
  }

  private func pickerTitle(_ row: KnownSpeakerRow) -> String {
    let samples =
      row.activeSampleCount == 1 ? "1 voice sample" : "\(row.activeSampleCount) voice samples"
    let tag = row.state == .needsReenrollment ? " · needs re-enrollment" : ""
    return "\(row.name) — \(samples)\(tag)"
  }

  /// Recent and matching names under the field, floating like a menu.
  private func suggestionList(for id: UUID) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(model.suggestions, id: \.self) { name in
        SuggestionRow(name: name) { model.pick(name, for: id) }
      }
    }
    .padding(6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SottoPalette.surface, in: .rect(cornerRadius: 12))
    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(NotetakerStyle.rule, lineWidth: 1) }
    .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    .transition(.opacity)
  }

  private struct SuggestionRow: View {
    let name: String
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
      Button(action: pick) {
        Text(name).font(.system(size: 15))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12).padding(.vertical, 10)
          .background(hovering ? SottoPalette.canvas : .clear, in: .rect(cornerRadius: 8))
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .accessibilityLabel("Use name \(name)")
    }
  }
}

/// Wispr's dialog buttons: a quiet gray Cancel and a filled Save names.
struct AssignSpeakersButtonStyle: ButtonStyle {
  let prominent: Bool
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .medium))
      .padding(.horizontal, 18).frame(height: 38)
      .foregroundStyle(prominent ? SottoPalette.surface : SottoPalette.ink)
      .background(prominent ? SottoPalette.ink : SottoPalette.canvas, in: .rect(cornerRadius: 9))
      .opacity(configuration.isPressed ? 0.8 : isEnabled ? 1 : 0.45)
  }
}
