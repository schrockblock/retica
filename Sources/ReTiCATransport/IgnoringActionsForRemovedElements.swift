import ComposableArchitecture

/// Runs `base`, except that actions addressed to a collection element that no longer exists are
/// dropped as a quiet no-op instead of reaching `base`'s `.forEach`, which would `reportIssue`
/// ("received an action for a missing element") and then ignore them anyway.
///
/// Such actions are expected, not bugs: TCA drains effect-emitted actions breadth-first, so one
/// chain can remove an element while a sibling chain's action for it is already queued. The
/// element's running effects are cancelled on removal by `.forEach` itself; this only covers
/// actions that were emitted before that point.
///
/// Wrap the whole reducer (parent `Reduce` included), so the parent's own handlers for element
/// delegates never see a late action either.
package struct IgnoringActionsForRemovedElements<Base: Reducer>: Reducer {
    package typealias State = Base.State
    package typealias Action = Base.Action

    let isForRemovedElement: (Base.State, Base.Action) -> Bool
    let base: Base

    package init(_ base: Base, isForRemovedElement: @escaping (Base.State, Base.Action) -> Bool) {
        self.base = base
        self.isForRemovedElement = isForRemovedElement
    }

    package func reduce(into state: inout Base.State, action: Base.Action) -> Effect<Base.Action> {
        if isForRemovedElement(state, action) { return .none }
        return base.reduce(into: &state, action: action)
    }
}
