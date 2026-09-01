import SceneKit
import SwiftUI

struct DeckAssembly: View, @MainActor Animatable {
  var app: AppState
  var progress: CGFloat

  init(app: AppState) {
    self.app = app
    self.progress = app.deck.progress
  }

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    ZStack(alignment: .top) {
      if app.deck.isDetached {
        ChassisBayView(app: app)
      } else if app.deck.isExpanded || progress > 0.001 {
        DeckSceneView(
          progress: progress,
          displayVisible: app.deck.isDisplayPowered,
          onWarmupFinished: { [weak app] in app?.deck.sceneWarmupDidFinish() },
          onDismantled: { [weak app] in app?.deck.sceneWasDismantled() }
        )
        .frame(height: DeckMechanism.sceneHeight)
        .accessibilityHidden(true)
        DeckPanel(app: app, open: app.deck.isExpanded, powered: app.deck.isDisplayPowered)
          .padding(.horizontal, DeckMechanism.sideInset)
          .modifier(DeckFaceProjection(progress: progress))
          .padding(.top, DeckMechanism.hingeGap)
          .opacity(app.deck.isDisplayPowered ? 1 : 0)
          .allowsHitTesting(app.deck.isSeated)
      }
    }
    .frame(height: DeckMechanism.reservedHeight(progress), alignment: .top)
    .clipped()
  }
}

private struct DeckSceneView: NSViewRepresentable {
  var progress: CGFloat
  var displayVisible: Bool
  var onWarmupFinished: @MainActor () -> Void
  var onDismantled: @MainActor () -> Void

  func makeCoordinator() -> DeckSceneCoordinator {
    DeckSceneCoordinator(onWarmupFinished: onWarmupFinished, onDismantled: onDismantled)
  }

  func makeNSView(context: Context) -> DeckSCNView {
    let view = DeckSCNView()
    view.backgroundColor = .clear
    view.antialiasingMode = .multisampling4X
    view.rendersContinuously = true
    view.isJitteringEnabled = false
    view.allowsCameraControl = false
    view.autoenablesDefaultLighting = false
    context.coordinator.attach(to: view)
    return view
  }

  func updateNSView(_ view: DeckSCNView, context: Context) {
    context.coordinator.apply(progress: progress, displayVisible: displayVisible)
  }

  static func dismantleNSView(_ view: DeckSCNView, coordinator: DeckSceneCoordinator) {
    coordinator.dismantle()
  }
}

struct DeckFaceProjection: GeometryEffect {
  var progress: CGFloat

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func effectValue(size: CGSize) -> ProjectionTransform {
    let theta = DeckMechanism.angle(progress)
    let sine = sin(theta)
    let cosine = cos(theta)
    let depth = DeckMechanism.thickness / 2
    let camera = DeckMechanism.cameraDistance
    let cameraY = DeckMechanism.sceneHeight / 2 - DeckMechanism.hingeGap

    let a = (camera + depth - depth * cosine) / camera
    let b = sine / camera
    let centerX = size.width / 2
    let yCoefficient = cameraY * b + cosine
    let yConstant = cameraY * (a - 1) + depth * sine

    var transform = CATransform3DIdentity
    transform.m11 = 1
    transform.m21 = centerX * b
    transform.m41 = centerX * (a - 1)
    transform.m22 = yCoefficient
    transform.m42 = yConstant
    transform.m24 = b
    transform.m44 = a
    return ProjectionTransform(transform)
  }
}

final class DeckSCNView: SCNView {
  var blocksClicks = false
  var onLayout: (() -> Void)?
  var contentClipHeight: CGFloat = 0
  var overlayCutout: [NSPoint]?

  override var mouseDownCanMoveWindow: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    blocksClicks ? super.hitTest(point) : nil
  }

  override func layout() {
    super.layout()
    onLayout?()
  }
}

@MainActor
final class DeckSceneCoordinator: NSObject, SCNSceneRendererDelegate {
  private weak var view: DeckSCNView?
  private var pivot: SCNNode?
  private var dogs: [SCNNode] = []
  private var builtWidth: CGFloat = 0
  private var progress: CGFloat = 0
  private var displayVisible = false
  private var isPrewarming = true
  private var warmupDeadline: Task<Void, Never>?
  private var onWarmupFinished: (() -> Void)?
  private var onDismantled: (() -> Void)?

  init(onWarmupFinished: @escaping () -> Void, onDismantled: @escaping () -> Void) {
    self.onWarmupFinished = onWarmupFinished
    self.onDismantled = onDismantled
  }

  func attach(to view: DeckSCNView) {
    self.view = view
    view.delegate = self
    let scene = SCNScene()
    scene.background.contents = NSColor.clear
    view.scene = scene
    buildRig(in: scene.rootNode)
    view.onLayout = { [weak self] in self?.rebuildIfNeeded() }
    view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
    warmupDeadline = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(500))
      } catch {
        return
      }
      self?.finishPrewarming(requiresRenderedDoor: false)
    }
  }

  nonisolated func renderer(
    _ renderer: any SCNSceneRenderer,
    didRenderScene scene: SCNScene,
    atTime time: TimeInterval
  ) {
    Task { @MainActor [weak self] in
      self?.finishPrewarming(requiresRenderedDoor: true)
    }
  }

  /// Tears down the scene when SwiftUI removes the view: releases the SCNView's
  /// scene graph and render buffers, and tells the presenter to arm a fresh
  /// warmup latch for the next mount.
  func dismantle() {
    finishPrewarming(requiresRenderedDoor: false)
    view?.scene = nil
    view = nil
    pivot = nil
    dogs.removeAll()
    let dismantled = onDismantled
    onDismantled = nil
    dismantled?()
  }

  func apply(progress: CGFloat, displayVisible: Bool) {
    self.progress = progress
    self.displayVisible = displayVisible
    rebuildIfNeeded()
    pose()
  }

  // MARK: - Static rig

  private func buildRig(in root: SCNNode) {
    let camera = SCNCamera()
    camera.projectionDirection = .vertical
    camera.fieldOfView =
      2 * atan((DeckMechanism.sceneHeight / 2) / DeckMechanism.cameraDistance) * 180 / .pi
    camera.zNear = 50
    camera.zFar = 2500
    let cameraNode = SCNNode()
    cameraNode.name = "camera"
    cameraNode.camera = camera
    cameraNode.position = SCNVector3(0, 0, DeckMechanism.cameraDistance)
    root.addChildNode(cameraNode)

    let ambient = SCNNode()
    ambient.light = SCNLight()
    ambient.light?.type = .ambient
    ambient.light?.intensity = 380
    ambient.light?.color = NSColor(white: 1, alpha: 1)
    root.addChildNode(ambient)

    let key = SCNNode()
    key.light = SCNLight()
    key.light?.type = .spot
    key.light?.intensity = 900
    key.light?.spotInnerAngle = 30
    key.light?.spotOuterAngle = 135
    key.light?.castsShadow = true
    key.light?.shadowMapSize = CGSize(width: 1024, height: 1024)
    key.light?.shadowRadius = 5
    key.light?.shadowSampleCount = 8
    key.light?.shadowColor = NSColor(white: 0, alpha: 0.55)
    key.light?.zNear = 100
    key.light?.zFar = 1600
    key.position = SCNVector3(0, 280, 430)
    key.eulerAngles.x = -atan2(280 + 40, 430)
    root.addChildNode(key)

    let fill = SCNNode()
    fill.light = SCNLight()
    fill.light?.type = .directional
    fill.light?.intensity = 140
    fill.light?.color = NSColor(srgbRed: 0.85, green: 0.9, blue: 1, alpha: 1)
    fill.eulerAngles.x = .pi / 5
    root.addChildNode(fill)

    let cavity = SCNNode(geometry: SCNPlane(width: 4000, height: 400))
    cavity.geometry?.firstMaterial = Self.flatMaterial(Bodywork.nsGrey(Bodywork.Level.cavity))
    cavity.position = SCNVector3(0, 0, -140)
    cavity.castsShadow = false
    root.addChildNode(cavity)
  }

  // MARK: - door

  private func rebuildIfNeeded() {
    guard let view, let root = view.scene?.rootNode else { return }
    let width = view.bounds.width
    guard width > DeckMechanism.sideInset * 2 + 40 else { return }
    guard abs(width - builtWidth) > 0.5 else { return }
    builtWidth = width
    pivot?.removeFromParentNode()
    dogs.removeAll()
    pivot = buildDoor(width: width)
    root.addChildNode(pivot!)
    pose()
  }

  private func buildDoor(width: CGFloat) -> SCNNode {
    let faceWidth = width - DeckMechanism.sideInset * 2
    let faceHeight = DeckMechanism.faceHeight
    let halfDepth = DeckMechanism.thickness / 2
    let faceCenterY = -faceHeight / 2

    let node = SCNNode()
    node.name = "deckPivot"
    node.position = SCNVector3(
      0, DeckMechanism.sceneHeight / 2 - DeckMechanism.hingeGap, -halfDepth)

    let outline = NSBezierPath(
      roundedRect: NSRect(
        x: -faceWidth / 2, y: -faceHeight / 2, width: faceWidth, height: faceHeight),
      xRadius: DeckMechanism.cornerRadius, yRadius: DeckMechanism.cornerRadius)
    outline.flatness = 0.1
    let slabGeometry = SCNShape(path: outline, extrusionDepth: DeckMechanism.thickness)
    slabGeometry.chamferRadius = DeckMechanism.bevel
    slabGeometry.chamferMode = .both
    slabGeometry.materials = [
      Self.bodyMaterial(0.19),  // front face
      Self.bodyMaterial(0.05),  // back face
      Self.bodyMaterial(0.1, specular: 0.35),  // sides
      Self.bodyMaterial(0.32, specular: 0.55),  // front chamfer
      Self.bodyMaterial(0.08),  // back chamfer
    ]
    let slab = SCNNode(geometry: slabGeometry)
    slab.position = SCNVector3(0, faceCenterY, 0)
    node.addChildNode(slab)

    let glassGeometry = SCNPlane(
      width: faceWidth - 20,
      height: faceHeight - 18)
    let material = Self.flatMaterial(NSColor.black)
    glassGeometry.firstMaterial = material
    let glass = SCNNode(geometry: glassGeometry)
    glass.position = SCNVector3(0, faceCenterY, halfDepth + 0.05)
    glass.castsShadow = false
    node.addChildNode(glass)

    let barrelLength = max(34, faceWidth * 0.24)
    for direction in [CGFloat(-1), 1] {
      let barrel = SCNNode(
        geometry: SCNCylinder(radius: 4.5, height: barrelLength))
      barrel.geometry?.firstMaterial = Self.bodyMaterial(0.2, specular: 0.65, shininess: 0.5)
      barrel.eulerAngles.z = .pi / 2
      barrel.position = SCNVector3(direction * (barrelLength / 2 + 30), 0, 0)
      node.addChildNode(barrel)
    }

    let gearbox = SCNNode(geometry: SCNBox(width: 48, height: 11, length: 12, chamferRadius: 2.5))
    gearbox.geometry?.firstMaterial = Self.bodyMaterial(0.11, specular: 0.3)
    node.addChildNode(gearbox)
    for offset in [-8.0, 0, 8.0] {
      let rib = SCNNode(geometry: SCNBox(width: 1.6, height: 8, length: 1.2, chamferRadius: 0.4))
      rib.geometry?.firstMaterial = Self.bodyMaterial(0.3, specular: 0.5)
      rib.position = SCNVector3(offset, 0, 6.2)
      node.addChildNode(rib)
    }

    for direction in [CGFloat(-1), 1] {
      let railX = direction * (faceWidth / 2 - 6)
      let rail = SCNNode(geometry: SCNBox(width: 5, height: 54, length: 3.5, chamferRadius: 1.4))
      rail.geometry?.firstMaterial = Self.bodyMaterial(0.26, specular: 0.55)
      rail.position = SCNVector3(railX, faceCenterY, halfDepth + 1.4)
      node.addChildNode(rail)
      for capOffset in [CGFloat(-27), 27] {
        let cap = SCNNode(geometry: SCNCylinder(radius: 2.6, height: 1.4))
        cap.geometry?.firstMaterial = Self.bodyMaterial(0.2, specular: 0.7, shininess: 0.6)
        cap.eulerAngles.x = .pi / 2
        cap.position = SCNVector3(railX, faceCenterY + capOffset, halfDepth + 3.2)
        node.addChildNode(cap)
      }
    }

    for (xSign, yInset) in [
      (CGFloat(-1), CGFloat(15)), (1, 15), (-1, faceHeight - 15), (1, faceHeight - 15),
    ] {
      let head = SCNNode(geometry: SCNCylinder(radius: 2.4, height: 1))
      head.geometry?.firstMaterial = Self.bodyMaterial(0.3, specular: 0.7, shininess: 0.7)
      head.eulerAngles.x = .pi / 2
      head.position = SCNVector3(xSign * (faceWidth / 2 - 6.5), -yInset, halfDepth + 0.4)
      node.addChildNode(head)
      let slot = SCNNode(geometry: SCNBox(width: 3.4, height: 0.7, length: 0.5, chamferRadius: 0))
      slot.geometry?.firstMaterial = Self.bodyMaterial(0.04)
      slot.eulerAngles.z = xSign * .pi / 10
      slot.position = SCNVector3(xSign * (faceWidth / 2 - 6.5), -yInset, halfDepth + 1)
      node.addChildNode(slot)
    }

    let dogSpacing = (faceWidth - 60) / 3
    for index in 0..<4 {
      let dog = SCNNode(
        geometry: SCNBox(width: 9, height: 7, length: 5, chamferRadius: 1.2))
      dog.geometry?.firstMaterial = Self.bodyMaterial(0.22, specular: 0.4)
      dog.position = SCNVector3(
        -dogSpacing * 1.5 + dogSpacing * CGFloat(index), Self.dogRestY, halfDepth - 2)
      node.addChildNode(dog)
      dogs.append(dog)
    }

    return node
  }

  private static let dogRestY: CGFloat = -DeckMechanism.faceHeight - 1

  private func pose() {
    guard let pivot, let view else { return }
    SCNTransaction.begin()
    SCNTransaction.animationDuration = 0
    pivot.eulerAngles.x = DeckMechanism.angle(progress)
    let dogLift = DeckMechanism.dogTravel(progress) * 6
    for dog in dogs {
      dog.position.y = Self.dogRestY + dogLift
    }
    SCNTransaction.commit()
    view.blocksClicks = progress > 0.001
    view.contentClipHeight = DeckMechanism.reservedHeight(progress)
    if displayVisible {
      let inset = DeckMechanism.sideInset + 10
      let halfGlassWidth = (view.bounds.width - inset * 2) / 2
      let top = CGFloat(9)
      let bottom = DeckMechanism.faceHeight - 9
      func point(x: CGFloat, u: CGFloat) -> NSPoint {
        let screenX =
          view.bounds.midX + x * DeckMechanism.projectedScale(u: u, progress: progress)
        let screenY = DeckMechanism.projectedY(u: u, progress: progress)
        return NSPoint(x: screenX, y: view.bounds.height - screenY)
      }
      view.overlayCutout = [
        point(x: -halfGlassWidth, u: top), point(x: halfGlassWidth, u: top),
        point(x: halfGlassWidth, u: bottom), point(x: -halfGlassWidth, u: bottom),
      ]
    } else {
      view.overlayCutout = nil
    }
  }

  private func finishPrewarming(requiresRenderedDoor: Bool) {
    guard isPrewarming else { return }
    if requiresRenderedDoor {
      guard builtWidth > 0, pivot != nil else { return }
    }
    isPrewarming = false
    warmupDeadline?.cancel()
    warmupDeadline = nil
    view?.delegate = nil
    view?.rendersContinuously = false
    let completion = onWarmupFinished
    onWarmupFinished = nil
    completion?()
  }

  // MARK: - Materials

  private static func bodyMaterial(
    _ level: CGFloat, specular: CGFloat = 0.2, shininess: CGFloat = 0.3
  ) -> SCNMaterial {
    let material = SCNMaterial()
    material.lightingModel = .blinn
    material.diffuse.contents = Bodywork.nsGrey(level)
    material.specular.contents = NSColor(white: specular, alpha: 1)
    material.shininess = shininess
    material.locksAmbientWithDiffuse = true
    return material
  }

  private static func flatMaterial(_ color: NSColor) -> SCNMaterial {
    let material = SCNMaterial()
    material.lightingModel = .constant
    material.diffuse.contents = color
    return material
  }

}
