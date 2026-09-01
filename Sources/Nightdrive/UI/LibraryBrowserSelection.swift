import Foundation

enum LibraryBrowserSelectionChange {
  case destination
  case collectionData
  case collections(Set<LibraryCollection.ID>)
  case tracks(Set<TrackID>)
}

struct LibraryBrowserSelectionTransition: Equatable {
  let collectionIDs: Set<LibraryCollection.ID>
  let trackIDs: Set<TrackID>
}

enum LibraryBrowserSelection {
  static func transition(
    for change: LibraryBrowserSelectionChange,
    currentCollectionIDs: Set<LibraryCollection.ID>,
    selectedTrackIDs: Set<TrackID>,
    collections: [LibraryCollection],
    projectedCollectionIDs: Set<LibraryCollection.ID>? = nil,
    isValidCollectionID: ((LibraryCollection.ID) -> Bool)? = nil
  ) -> LibraryBrowserSelectionTransition {
    let validIDs = isValidCollectionID == nil ? Set(collections.map(\.id)) : []
    func validated(_ ids: Set<LibraryCollection.ID>) -> Set<LibraryCollection.ID> {
      if let isValidCollectionID {
        return Set(ids.filter(isValidCollectionID))
      }
      return ids.intersection(validIDs)
    }
    let currentIDs = validated(currentCollectionIDs)

    switch change {
    case .destination:
      let projectedIDs =
        projectedCollectionIDs
        ?? LibraryCollection.ids(containingAny: selectedTrackIDs, in: collections)
      return LibraryBrowserSelectionTransition(
        collectionIDs: preferredScope(projectedIDs, currentIDs, collections: collections),
        trackIDs: selectedTrackIDs)

    case .collectionData:
      let projectedIDs =
        currentIDs.isEmpty
        ? projectedCollectionIDs
          ?? LibraryCollection.ids(containingAny: selectedTrackIDs, in: collections)
        : []
      return LibraryBrowserSelectionTransition(
        collectionIDs: preferredScope(currentIDs, projectedIDs, collections: collections),
        trackIDs: selectedTrackIDs)

    case .collections(let requestedIDs):
      let collectionIDs = preferredScope(
        validated(requestedIDs), [], collections: collections)
      let visibleTrackIDs = Set(
        LibraryCollection.combinedTracks(
          from: collections.filter { collectionIDs.contains($0.id) }
        ).map(\.id))
      return LibraryBrowserSelectionTransition(
        collectionIDs: collectionIDs,
        trackIDs: selectedTrackIDs.intersection(visibleTrackIDs))

    case .tracks(let requestedIDs):
      return LibraryBrowserSelectionTransition(
        collectionIDs: currentIDs,
        trackIDs: requestedIDs)
    }
  }

  static func contextCollectionIDs(
    for clickedIDs: Set<LibraryCollection.ID>,
    selectedCollectionIDs: Set<LibraryCollection.ID>,
    collections: [LibraryCollection]
  ) -> Set<LibraryCollection.ID> {
    guard !clickedIDs.isEmpty else { return [] }
    let effectiveIDs =
      clickedIDs.isSubset(of: selectedCollectionIDs) ? selectedCollectionIDs : clickedIDs
    return effectiveIDs.intersection(collections.map(\.id))
  }

  private static func preferredScope(
    _ firstChoice: Set<LibraryCollection.ID>,
    _ secondChoice: Set<LibraryCollection.ID>,
    collections: [LibraryCollection]
  ) -> Set<LibraryCollection.ID> {
    if !firstChoice.isEmpty { return firstChoice }
    if !secondChoice.isEmpty { return secondChoice }
    return Set(collections.prefix(1).map(\.id))
  }
}
