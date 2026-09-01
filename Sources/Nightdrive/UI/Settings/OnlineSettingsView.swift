import SwiftUI

struct OnlineSettingsView: View {
  @Bindable var policy: OnlineServicesPolicy
  var openSuggestions: () -> Void = {}
  var openPodcasts: () -> Void = {}

  var body: some View {
    SettingsPaneScroll {
      lookupSection
      podcastsSection
    }
  }

  private var lookupSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      SettingsHeading(String(localized: "Metadata Lookup"))

      SettingsCard {
        SettingsSwitchRow(
          String(localized: "Look up song metadata on MusicBrainz"),
          subtitle: String(
            localized: "Allows Nightdrive to contact musicbrainz.org to match your songs."),
          isOn: consentBinding)
        SettingsCardDivider()
        SettingsSwitchRow(
          String(localized: "Automatically look up missing metadata"),
          subtitle: String(localized: "Matches albums missing tags after each library scan."),
          isOn: autoLookupBinding
        )
        .disabled(!policy.isEnabled)
        .opacity(policy.isEnabled ? 1 : 0.4)
      }

      SettingsFootnote(
        String(
          localized:
            "Lookups match your songs against MusicBrainz, a community-maintained music encyclopedia, to fill in missing or incorrect tags (like titles, artists, albums, track numbers, and release years). Start one from a song's info editor or an album's Look Up action, or let automatic lookup match albums after each library scan. Suggested changes wait in the Suggestions inbox until you approve them."
        ))

      Button("Open the Suggestions inbox", action: openSuggestions)
        .buttonStyle(.link)
        .font(.caption)
        .padding(.horizontal, 3)

      whatGetsSentLabel

      SettingsCard {
        infoRow(
          symbol: "text.quote",
          title: String(localized: "Only tag text"),
          caption: String(
            localized:
              "A lookup sends the artist, album, and song title already tagged on your files — nothing else.")
        )
        SettingsCardDivider()
        infoRow(
          symbol: "nosign",
          title: String(localized: "Never your music"),
          caption: String(
            localized:
              "Audio files, file paths, folder names, and listening history never leave this Mac.")
        )
        SettingsCardDivider()
        infoRow(
          symbol: "building.columns",
          title: String(localized: "A non-profit service"),
          caption: String(
            localized:
              "MusicBrainz is an open music encyclopedia run by the MetaBrainz Foundation, a California non-profit.")
        )
      }

      HStack(spacing: 4) {
        Text("Read the")
          .font(.caption)
          .foregroundStyle(.secondary)
        Link(
          "MetaBrainz privacy policy", destination: URL(string: "https://metabrainz.org/privacy")!
        )
        .font(.caption)
      }
      .padding(.horizontal, 3)
    }
  }

  private var podcastsSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      SettingsHeading(String(localized: "Podcasts"))

      SettingsCard {
        SettingsSwitchRow(
          String(localized: "Search and download podcasts"),
          subtitle: String(
            localized:
              "Allows Nightdrive to contact Apple's podcast directory and each show's publisher."),
          isOn: podcastsConsentBinding)
        SettingsCardDivider()
        SettingsSwitchRow(
          String(localized: "Automatically check shows for new episodes"),
          subtitle: String(
            localized: "Refreshes your subscribed shows shortly after Nightdrive opens."),
          isOn: podcastAutoRefreshBinding
        )
        .disabled(!policy.isPodcastsEnabled)
        .opacity(policy.isPodcastsEnabled ? 1 : 0.4)
      }

      SettingsFootnote(
        String(
          localized:
            "Shows are found through Apple's podcast directory, and episodes download straight from each publisher's feed. Downloaded episodes join your library and sync to your iPod's Podcasts menu."
        ))

      Button("Open Podcasts", action: openPodcasts)
        .buttonStyle(.link)
        .font(.caption)
        .padding(.horizontal, 3)

      whatGetsSentLabel

      SettingsCard {
        infoRow(
          symbol: "magnifyingglass",
          title: String(localized: "Only search terms"),
          caption: String(
            localized:
              "Searching and the Popular list contact Apple's podcast directory with your search text — nothing about your library."
          )
        )
        SettingsCardDivider()
        infoRow(
          symbol: "antenna.radiowaves.left.and.right",
          title: String(localized: "Feeds come from publishers"),
          caption: String(
            localized:
              "Loading a show or downloading an episode contacts that show's publisher directly, like any podcast app.")
        )
        SettingsCardDivider()
        infoRow(
          symbol: "nosign",
          title: String(localized: "Never your listening"),
          caption: String(
            localized:
              "Subscriptions, downloads, and playback history never leave this Mac.")
        )
      }
    }
  }

  private var whatGetsSentLabel: some View {
    Text("What gets sent")
      .font(.caption)
      .fontWeight(.semibold)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 3)
      .padding(.top, 4)
  }

  private func infoRow(symbol: String, title: String, caption: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 15))
        .foregroundStyle(.tint)
        .frame(width: 20)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 13, weight: .medium))
        Text(caption)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .accessibilityElement(children: .combine)
  }

  private var consentBinding: Binding<Bool> {
    Binding(
      get: { policy.isEnabled },
      set: { policy.setConsent($0 ? .enabled : .disabled) })
  }

  private var podcastsConsentBinding: Binding<Bool> {
    Binding(
      get: { policy.isPodcastsEnabled },
      set: { policy.setPodcastsConsent($0 ? .enabled : .disabled) })
  }

  private var podcastAutoRefreshBinding: Binding<Bool> {
    Binding(
      get: { policy.isPodcastAutoRefreshActive },
      set: { policy.setPodcastAutoRefresh($0) })
  }

  private var autoLookupBinding: Binding<Bool> {
    Binding(
      get: { policy.isAutoLookupActive },
      set: { policy.setAutoLookup($0) })
  }
}
