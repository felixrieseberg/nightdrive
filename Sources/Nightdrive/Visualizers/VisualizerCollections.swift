extension Array {
  init(reservingCapacity capacity: Int) {
    self.init()
    reserveCapacity(capacity)
  }
}
