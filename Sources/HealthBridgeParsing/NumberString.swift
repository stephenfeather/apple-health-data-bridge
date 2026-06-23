import Foundation

/// Lossless number rendering for ObservationID stability (no %g rounding); integral values drop the .0.
/// Guards the Int conversion so huge/non-finite Doubles (e.g. 1e20) don't trap `String(Int(d))`
/// (the crash fixed in PR #1's FHIRParser). Shared by FHIRParser and CCDAParser as the single source
/// of truth, so both derive byte-identical ids for identical clinical content.
func stableNumberString(_ d: Double) -> String {
    guard d.isFinite else { return String(d) }
    if d.truncatingRemainder(dividingBy: 1) == 0, d >= Double(Int.min), d < Double(Int.max) { return String(Int(d)) }
    return String(d)
}
