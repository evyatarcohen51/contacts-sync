// Stand-in for the parts of SwiftUI the app uses: enough to type-check the views with the
// same shapes (result builders, property wrappers, main-actor isolation) as the real thing.
// Nothing here draws anything.
@_exported import Combine
@_exported import Foundation
import UIKit

// MARK: - View

@MainActor @preconcurrency
public protocol View {
    associatedtype Body: View
    @ViewBuilder @MainActor @preconcurrency var body: Body { get }
}

extension Never: View {
    public var body: Never { fatalError() }
}

/// A leaf view with no body of its own.
public protocol PrimitiveView: View where Body == Never {}
extension PrimitiveView {
    public var body: Never { fatalError("stub views are never rendered") }
}

public struct EmptyView: PrimitiveView { public init() {} }
public struct AnyView: PrimitiveView { public init<V: View>(_ view: V) {} }
public struct TupleView<T>: PrimitiveView { public init(_ value: T) {} }
public struct _ConditionalContent<TrueContent: View, FalseContent: View>: PrimitiveView {}
public struct ModifiedContent<Content: View>: PrimitiveView {}
extension Optional: View where Wrapped: View {
    public var body: Never { fatalError() }
}

@resultBuilder
public struct ViewBuilder {
    public static func buildExpression<Content: View>(_ content: Content) -> Content { content }
    public static func buildBlock() -> EmptyView { EmptyView() }
    public static func buildBlock<Content: View>(_ content: Content) -> Content { content }
    public static func buildBlock<each Content: View>(_ content: repeat each Content) -> TupleView<(repeat each Content)> {
        TupleView((repeat each content))
    }
    public static func buildIf<Content: View>(_ content: Content?) -> Content? { content }
    public static func buildEither<T: View, F: View>(first: T) -> _ConditionalContent<T, F> { _ConditionalContent() }
    public static func buildEither<T: View, F: View>(second: F) -> _ConditionalContent<T, F> { _ConditionalContent() }
    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> AnyView { AnyView(content) }
}

// MARK: - Values used by modifiers

public struct LocalizedStringKey: ExpressibleByStringInterpolation, Equatable {
    public init(_ value: String) {}
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: StringInterpolation) {}

    public struct StringInterpolation: StringInterpolationProtocol {
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) {}
        public mutating func appendInterpolation(_ string: String) {}
        public mutating func appendInterpolation<T>(_ value: T) where T: CustomStringConvertible {}
        public mutating func appendInterpolation(_ text: Text) {}
    }
}

public protocol ShapeStyle: Sendable {}

public struct Color: ShapeStyle, PrimitiveView, Hashable {
    let name: String
    public static let red = Color(name: "red")
    public static let green = Color(name: "green")
    public static let blue = Color(name: "blue")
    public static let primary = Color(name: "primary")
    public static let secondary = Color(name: "secondary")
}

public struct HierarchicalShapeStyle: ShapeStyle {
    public static let primary = HierarchicalShapeStyle()
    public static let secondary = HierarchicalShapeStyle()
}

extension ShapeStyle where Self == Color {
    public static var red: Color { .red }
    public static var green: Color { .green }
    public static var blue: Color { .blue }
}

extension ShapeStyle where Self == HierarchicalShapeStyle {
    public static var primary: HierarchicalShapeStyle { HierarchicalShapeStyle.primary }
    public static var secondary: HierarchicalShapeStyle { HierarchicalShapeStyle.secondary }
}

public struct Font: Hashable, Sendable {
    public struct Weight: Hashable, Sendable {
        public static let regular = Weight(), medium = Weight(), semibold = Weight(), bold = Weight()
    }
    public enum Design: Hashable, Sendable { case `default`, serif, rounded, monospaced }

    public static let largeTitle = Font(), title = Font(), headline = Font(), body = Font()
    public static let callout = Font(), footnote = Font(), caption = Font()
    public static func system(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font { Font() }
    public func weight(_ weight: Font.Weight) -> Font { self }
    public func bold() -> Font { self }
}

public enum TextAlignment: Hashable, Sendable { case leading, center, trailing }
public struct HorizontalAlignment: Equatable, Sendable {
    public static let leading = HorizontalAlignment(), center = HorizontalAlignment(), trailing = HorizontalAlignment()
}
public struct VerticalAlignment: Equatable, Sendable {
    public static let top = VerticalAlignment(), center = VerticalAlignment(), bottom = VerticalAlignment()
}
public struct Alignment: Equatable, Sendable {
    public static let center = Alignment(), leading = Alignment(), trailing = Alignment()
}

public enum Edge: Int8, Sendable {
    case top, leading, bottom, trailing

    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1), leading = Set(rawValue: 2)
        public static let bottom = Set(rawValue: 4), trailing = Set(rawValue: 8)
        public static let all: Set = [.top, .leading, .bottom, .trailing]
        public static let horizontal: Set = [.leading, .trailing]
        public static let vertical: Set = [.top, .bottom]
    }
}

public struct TextInputAutocapitalization: Sendable {
    public static var never: TextInputAutocapitalization { .init() }
    public static var words: TextInputAutocapitalization { .init() }
    public static var sentences: TextInputAutocapitalization { .init() }
    public static var characters: TextInputAutocapitalization { .init() }
}

public struct ButtonRole: Equatable, Sendable {
    public static let destructive = ButtonRole()
    public static let cancel = ButtonRole()
}

public protocol PickerStyle {}
public struct SegmentedPickerStyle: PickerStyle { public init() {} }
public struct MenuPickerStyle: PickerStyle { public init() {} }
extension PickerStyle where Self == SegmentedPickerStyle {
    public static var segmented: SegmentedPickerStyle { .init() }
}
extension PickerStyle where Self == MenuPickerStyle {
    public static var menu: MenuPickerStyle { .init() }
}

// MARK: - Views

public struct Text: PrimitiveView, Equatable {
    public struct DateStyle: Equatable, Sendable {
        public static let time = DateStyle(), date = DateStyle(), relative = DateStyle()
        public static let offset = DateStyle(), timer = DateStyle()
    }

    public init(_ key: LocalizedStringKey, tableName: String? = nil, bundle: Bundle? = nil, comment: StaticString? = nil) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ content: S) {}
    public init(_ date: Date, style: Text.DateStyle) {}

    public static func + (lhs: Text, rhs: Text) -> Text { lhs }
    public func font(_ font: Font?) -> Text { self }
    public func fontWeight(_ weight: Font.Weight?) -> Text { self }
    public func bold() -> Text { self }
}

public struct Button<Label: View>: PrimitiveView {
    public init(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {}
    public init(role: ButtonRole?, action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {}
}

extension Button where Label == Text {
    public init(_ titleKey: LocalizedStringKey, action: @escaping @MainActor () -> Void) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, action: @escaping @MainActor () -> Void) {}
    public init(_ titleKey: LocalizedStringKey, role: ButtonRole?, action: @escaping @MainActor () -> Void) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, role: ButtonRole?, action: @escaping @MainActor () -> Void) {}
}

public struct HStack<Content: View>: PrimitiveView {
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
}

public struct VStack<Content: View>: PrimitiveView {
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
}

public struct Spacer: PrimitiveView { public init(minLength: CGFloat? = nil) {} }

public struct ProgressView<Label: View, CurrentValueLabel: View>: PrimitiveView {}
extension ProgressView where Label == EmptyView, CurrentValueLabel == EmptyView {
    public init() {}
}

public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: PrimitiveView {}
extension Picker where Label == Text {
    public init(_ titleKey: LocalizedStringKey, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {}
    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {}
}

public struct Toggle<Label: View>: PrimitiveView {
    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {}
}
extension Toggle where Label == Text {
    public init(_ titleKey: LocalizedStringKey, isOn: Binding<Bool>) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>) {}
}

public struct TextField<Label: View>: PrimitiveView {}
extension TextField where Label == Text {
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>) {}
}

public struct NavigationStack<Root: View>: PrimitiveView {
    public init(@ViewBuilder root: () -> Root) {}
}

public struct NavigationLink<Label: View, Destination: View>: PrimitiveView {
    public init(@ViewBuilder destination: () -> Destination, @ViewBuilder label: () -> Label) {}
}
extension NavigationLink where Label == Text {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder destination: () -> Destination) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder destination: () -> Destination) {}
}

public struct LabeledContent<Label: View, Content: View>: PrimitiveView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {}
}
extension LabeledContent where Label == Text {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {}
}

public struct Image: PrimitiveView { public init(systemName: String) {} }

public struct Label<Title: View, Icon: View>: PrimitiveView {
    public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) {}
}
extension Label where Title == Text, Icon == Image {
    public init(_ titleKey: LocalizedStringKey, systemImage name: String) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage name: String) {}
}

public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: PrimitiveView {}
extension ForEach where ID == Data.Element.ID, Data.Element: Identifiable {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {}
}

public struct Form<Content: View>: PrimitiveView {
    public init(@ViewBuilder content: () -> Content) {}
}

public struct Section<Parent: View, Content: View, Footer: View>: PrimitiveView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent, @ViewBuilder footer: () -> Footer) {}
}
extension Section where Parent == EmptyView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {}
}
extension Section where Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) {}
}
extension Section where Parent == EmptyView, Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content) {}
}
extension Section where Parent == Text, Footer == EmptyView {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {}
}

// MARK: - Modifiers

extension View {
    public func font(_ font: Font?) -> some View { ModifiedContent<Self>() }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> some View { ModifiedContent<Self>() }
    public func multilineTextAlignment(_ alignment: TextAlignment) -> some View { ModifiedContent<Self>() }
    public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View { ModifiedContent<Self>() }
    public func padding(_ length: CGFloat) -> some View { ModifiedContent<Self>() }
    public func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        ModifiedContent<Self>()
    }
    public func frame(
        minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil,
        alignment: Alignment = .center
    ) -> some View { ModifiedContent<Self>() }
    public func disabled(_ disabled: Bool) -> some View { ModifiedContent<Self>() }
    public func pickerStyle<S: PickerStyle>(_ style: S) -> some View { ModifiedContent<Self>() }
    public func tag<V: Hashable>(_ tag: V) -> some View { ModifiedContent<Self>() }
    public func keyboardType(_ type: UIKeyboardType) -> some View { ModifiedContent<Self>() }
    public func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View {
        ModifiedContent<Self>()
    }
    public func autocorrectionDisabled(_ disable: Bool = true) -> some View { ModifiedContent<Self>() }
    public func navigationTitle(_ titleKey: LocalizedStringKey) -> some View { ModifiedContent<Self>() }
    @_disfavoredOverload
    public func navigationTitle<S: StringProtocol>(_ title: S) -> some View { ModifiedContent<Self>() }
    public func onAppear(perform action: (() -> Void)? = nil) -> some View { ModifiedContent<Self>() }
    public func onDisappear(perform action: (() -> Void)? = nil) -> some View { ModifiedContent<Self>() }
    public func environmentObject<T: ObservableObject>(_ object: T) -> some View { ModifiedContent<Self>() }
}

// MARK: - State

@propertyWrapper @dynamicMemberLookup
public struct Binding<Value> {
    private let get: () -> Value
    private let set: (Value) -> Void
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) { self.get = get; self.set = set }
    public var wrappedValue: Value {
        get { get() }
        nonmutating set { set(newValue) }
    }
    public var projectedValue: Binding<Value> { self }
    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>) -> Binding<Subject> {
        Binding<Subject>(get: { wrappedValue[keyPath: keyPath] }, set: { wrappedValue[keyPath: keyPath] = $0 })
    }
}

@propertyWrapper
public struct State<Value> {
    private final class Box { var value: Value; init(_ v: Value) { value = v } }
    private let box: Box
    public init(wrappedValue value: Value) { box = Box(value) }
    public init(initialValue value: Value) { box = Box(value) }
    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    public var projectedValue: Binding<Value> {
        let box = box
        return Binding(get: { box.value }, set: { box.value = $0 })
    }
}

@propertyWrapper
public struct ObservedObject<ObjectType: ObservableObject> {
    @dynamicMemberLookup
    public struct Wrapper {
        let object: ObjectType
        public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, Subject>) -> Binding<Subject> {
            let object = object
            return Binding(get: { object[keyPath: keyPath] }, set: { object[keyPath: keyPath] = $0 })
        }
    }

    public init(wrappedValue: ObjectType) { self.wrappedValue = wrappedValue }
    @MainActor @preconcurrency public var wrappedValue: ObjectType
    @MainActor @preconcurrency public var projectedValue: Wrapper { Wrapper(object: wrappedValue) }
}

@propertyWrapper
public struct StateObject<ObjectType: ObservableObject> {
    private let thunk: () -> ObjectType
    public init(wrappedValue thunk: @autoclosure @escaping () -> ObjectType) { self.thunk = thunk }
    @MainActor @preconcurrency public var wrappedValue: ObjectType { thunk() }
    @MainActor @preconcurrency public var projectedValue: ObservedObject<ObjectType>.Wrapper {
        ObservedObject<ObjectType>.Wrapper(object: wrappedValue)
    }
}

@propertyWrapper
public struct EnvironmentObject<ObjectType: ObservableObject> {
    public typealias Wrapper = ObservedObject<ObjectType>.Wrapper
    public init() {}
    @MainActor @preconcurrency public var wrappedValue: ObjectType { fatalError("no environment in the stub") }
    @MainActor @preconcurrency public var projectedValue: Wrapper { Wrapper(object: wrappedValue) }
}

public struct DismissAction: Sendable {
    @MainActor @preconcurrency public func callAsFunction() {}
}

public struct EnvironmentValues {
    public init() {}
    public var dismiss: DismissAction { DismissAction() }
}

@propertyWrapper
public struct Environment<Value> {
    private let keyPath: KeyPath<EnvironmentValues, Value>
    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) { self.keyPath = keyPath }
    public var wrappedValue: Value { EnvironmentValues()[keyPath: keyPath] }
}

// MARK: - App and scenes

@MainActor @preconcurrency
public protocol Scene {
    associatedtype Body: Scene
    @SceneBuilder @MainActor @preconcurrency var body: Body { get }
}

extension Never: Scene {}

public protocol PrimitiveScene: Scene where Body == Never {}
extension PrimitiveScene {
    public var body: Never { fatalError("stub scenes are never rendered") }
}

@resultBuilder
public struct SceneBuilder {
    public static func buildExpression<Content: Scene>(_ content: Content) -> Content { content }
    public static func buildBlock<Content: Scene>(_ content: Content) -> Content { content }
}

public struct WindowGroup<Content: View>: PrimitiveScene {
    public init(@ViewBuilder content: () -> Content) {}
}

public struct ModifiedScene<Content: Scene>: PrimitiveScene {}

public struct BackgroundTask<Request, Response>: Sendable {}
extension BackgroundTask where Request == Void, Response == Void {
    public static func appRefresh(_ identifier: String) -> BackgroundTask<Void, Void> { BackgroundTask() }
}

extension Scene {
    public func backgroundTask<D: Sendable, R: Sendable>(
        _ task: BackgroundTask<D, R>, action: @escaping @Sendable (D) async -> R
    ) -> some Scene { ModifiedScene<Self>() }
}

@MainActor @preconcurrency
public protocol App {
    associatedtype Body: Scene
    @SceneBuilder @MainActor @preconcurrency var body: Body { get }
    @MainActor @preconcurrency init()
}

extension App {
    /// The real one starts the UI. Here it only proves the app links.
    @MainActor public static func main() {
        print("ContactSyncSender built for Linux (no UI). Run the tests instead: see run.sh")
    }
}
