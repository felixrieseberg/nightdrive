import CoreGraphics

enum DeckMechanism {
  static let faceHeight: CGFloat = 122
  static let hingeGap: CGFloat = 9
  static let sideInset = ChassisMetrics.edgeInset
  static let thickness: CGFloat = 14
  static let bevel: CGFloat = 1.6
  static let cornerRadius: CGFloat = 11
  static let foldedDegrees: CGFloat = 88
  static let cameraDistance: CGFloat = 800
  static let sceneHeight: CGFloat = 136
  static let openHeight: CGFloat = hingeGap + faceHeight

  static func angle(_ progress: CGFloat) -> CGFloat {
    (1 - progress) * foldedDegrees * .pi / 180
  }

  static func reservedHeight(_ progress: CGFloat) -> CGFloat {
    let travel = min(1, max(0, progress))
    let closed = cos(foldedDegrees * .pi / 180)
    let projected = cos(angle(travel))
    return openHeight * max(0, (projected - closed) / (1 - closed))
  }

  static func contentSpacing(_ progress: CGFloat) -> CGFloat {
    hingeGap * reservedHeight(progress) / openHeight
  }

  static func dogTravel(_ progress: CGFloat) -> CGFloat {
    min(1, max(0, (progress - 0.79) / 0.2))
  }

  static func projectedY(u: CGFloat, w: CGFloat = thickness / 2, progress: CGFloat) -> CGFloat {
    let theta = angle(progress)
    let y = hingeGap + u * cos(theta) + w * sin(theta)
    let z = w * cos(theta) - u * sin(theta) - thickness / 2
    let cameraY = sceneHeight / 2
    return cameraY + (y - cameraY) * cameraDistance / (cameraDistance - z)
  }

  static func projectedScale(
    u: CGFloat, w: CGFloat = thickness / 2, progress: CGFloat
  ) -> CGFloat {
    let theta = angle(progress)
    let z = w * cos(theta) - u * sin(theta) - thickness / 2
    return cameraDistance / (cameraDistance - z)
  }
}
