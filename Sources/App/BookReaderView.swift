/**
 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as
 published by the Free Software Foundation, either version 3 of the
 License, or (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
import FairApp
import UniformTypeIdentifiers
import WebKit

@available(macOS 12.0, iOS 15.0, *)
struct EBookScene : Scene {

    var body: some Scene {
        DocumentGroup(viewing: EPUBDocument.self, viewer: documentHostView)
            .commands { EBookCommands() }
    }

    func documentHostView(file: ReferenceFileDocumentConfiguration<EPUBDocument>) -> some View {
        let doc: EPUBDocument = file.document

        return BookContainerView(document: doc)
            .focusedSceneValue(\.document, file.document)
    }
}

struct BookContainerView : View {
    @ObservedObject var document: EPUBDocument
    @StateObject var bookViewState: BookViewState
    @SceneStorage("selectedChapter") var selection: String = ""

    init(document: EPUBDocument) {
        self.document = document
        self._bookViewState = .init(wrappedValue: document.createBookViewState())
    }

    /// Conversion from SceneStorage (which cannot take an optional) to the double-optional required by the list selection
    private var selectionBinding: Binding<String??> {
        Binding {
            selection == "" ? nil : selection // blank converts to nil selection
        } set: { newValue in
            self.selection = (newValue ?? "") ?? ""
        }
    }

//    func epubContainer(document doc: Document, bookViewState: BookViewState) -> some View {

    var body: some View {
        containerView
            .focusedSceneValue(\.bookViewState, bookViewState)
            .alertingError($bookViewState.errors)
    }

    var containerView: some View {
        BookReaderView(document: document, bookViewState: bookViewState, selection: selectionBinding)
    }
}

class BookViewState : WebViewState {
    @AppStorage("smoothScrolling") public var smoothScrolling = true

    @AppStorage("hmargin") var hmargin: Int = 40
    @AppStorage("vmargin") var vmargin: Int = 20

    @AppStorage("pageScale") var pageScale: Double = BookViewState.defaultScale {
        didSet {
            // TODO: make this @SceneStorage? We'd need to move it into a view…
            self.resetUserScripts(webView: self.webView)
        }
    }

    /// TODO: store in scenestorage to restore last position
    private var targetPosition: Double? = nil

    #if os(iOS)
    static let defaultScale = 4.0
    #else
    static let defaultScale = 2.0
    #endif

    let messsageHandler = MessageHandler()

    #if os(iOS)
    let preventZoomDelegate = PreventZoomDelegate()


    // An iOS scroll delegate that disables zooming (which messes up pagination)
    class PreventZoomDelegate : NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            nil
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            scrollView.pinchGestureRecognizer?.isEnabled = false
        }
    }
    #endif

    class MessageHandler : NSObject, WKScriptMessageHandlerWithReply {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
            dbg("received message:", message.name, "body:", message.body)
        }

//        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
//            <#code#>
//        }

//        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
//            dbg("message received:", message)
//            return (nil, nil)
//        }
    }

    override func createWebView() -> WKWebView {
        let webView = super.createWebView()
        #if os(iOS)
        webView.scrollView.delegate = preventZoomDelegate
        #endif
        resetUserScripts(webView: webView)
        return webView
    }

    func resetUserScripts(webView: WKWebView?) {
        guard let controller = webView?.configuration.userContentController else {
            return dbg("no userContentController")
        }

        let handlerName = "MSGHANDLER"

        let script = """
            function log(msg) {
                window.webkit.messageHandlers.\(handlerName).postMessage({ info: msg });
            }

            log("start user script");

            var meta = document.createElement('meta');
            meta.name = 'viewport';
            /*
            meta.content = 'initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
            */
            meta.content = 'user-scalable=no';
            var head = document.getElementsByTagName('head')[0];
            head.appendChild(meta);

            document.body.style.overflow = 'hidden';

            //document.body.style.scrollSnapType = 'x mandatory';
            //document.body.style.scrollSnapPointsX = 'repeat(800px)';

            document.body.style.height = '100vh';
            document.body.style.columnWidth = '100vh';
            document.body.style.webkitLineBoxContain = 'block glyphs replaced';

            document.body.style.marginTop = '\(vmargin)px';
            document.body.style.marginBottom = '\(vmargin)px';

            document.body.style.marginLeft = '\(hmargin)px';
            document.body.style.marginRight = '\(hmargin)px';
            document.body.style.columnGap = '\(hmargin*2)px';

            //document.body.style.display = 'flex';
            //document.body.style.flexDirection = 'column';

            // navigate one page in a book section, snapping to column bounds
            // direction: -1 for previous page, +1 for next page, 0 to simply snap to bounds
            // smooth: a boolean indicating whether to scroll smoothly or instantly
            // returns: the position (from 0.0–1.0) in the current section, or -1/+1 to indicate movement beyond the bounds of the section
            function movePage(direction, smooth) {
                let element = document.documentElement;
                let totalWidth = element.scrollWidth;
                let pos = window.scrollX;
                let screenWidth = element.clientWidth
                pos = Math.min(totalWidth, pos + (screenWidth * direction));
                let adjust = (pos % element.clientWidth);
                pos -= adjust;
                if (adjust > (screenWidth / 2.0)) {
                    pos += screenWidth;
                }

                window.scrollTo({ 'left': pos, 'behavior': smooth == true ? 'smooth' : 'instant' });

                if (pos < 0.0) {
                    return -1; // less than one indicates before beginning
                } else if (pos > (totalWidth - (screenWidth / 2.0))) {
                    return 1.1; // more than one indicates past end
                } else {
                    return position();
                }
            };

            // with no argument, returns the current scroll position;
            // with an argument, jumps to the given position and snaps to the nearest
            // page boundry
            function position(amount) {
                if (typeof amount !== 'undefined') {
                    let pos = document.documentElement.scrollWidth * amount;
                    window.scrollTo({ 'left': pos, 'behavior': 'instant' });
                    movePage(0, false); // snap to nearest page
                }
                // always return the resulting position
                let width = document.documentElement.scrollWidth
                if (typeof width !== 'number' || width <= 0) {
                    return 0.0;
                }
                return Math.max(0.0, Math.min(1.0, window.scrollX / width));
            };

            // Scales the body font size by the given amount, returning the current scale
            function scaleText(amount) {
                let style = document.documentElement.style;
                let pos = position();
                style.fontSize = Math.round(amount * 100) + '%';
                position(pos); // restore relative position
                return style.fontSize;
            };


            scaleText(\(pageScale)); // perform initial scaling
            function handleResize() {
                position(position()); // snap to nearest page boundry on resize
                log("window resized");
            };

            window.onresize = handleResize;


            log("complete user script");

            """

        // user scripts cannot be removed piecemeal, so just remove everything and re-add
        controller.removeAllUserScripts()
        controller.removeAllScriptMessageHandlers()

        controller.addScriptMessageHandler(messsageHandler, contentWorld: .defaultClient, name: handlerName)

        dbg("adding user script handler")

        controller.addUserScript(WKUserScript(source: script, injectionTime: WKUserScriptInjectionTime.atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
    }

    func movePage(by amount: Int, smooth: Bool? = nil) async throws -> Double? {
        guard let webView = self.webView else {
            throw AppError("No book render host installed")
        }

        let result = try await webView.evalJS("movePage(\(amount), \(smooth ?? smoothScrolling))")
        dbg("result:", result)
        if let navigation = result as? Double {
            return navigation
        } else {
            return nil
        }
    }

    /// Sets the position in the current section to the given value
    /// - Parameter target: the target position, from 0.0–1.0, or nil to simply query the position
    /// - Returns: the current position in the current section
    @discardableResult func position(_ target: Double? = nil) async throws -> Double? {
        guard let webView = self.webView else {
            throw AppError("No book render host installed")
        }

        let result = try await webView.evalJS("position(\(target?.description ?? ""))")
        dbg("position:", Self.percentParser.string(from: result as? NSNumber ?? -1))
        if let navigation = result as? Double {
            return navigation
        } else {
            return nil
        }
    }

    fileprivate static let percentParser: NumberFormatter = {
        let fmt = NumberFormatter()
        fmt.numberStyle = .percent
        return fmt
    }()

    func textScaleAction(brief: Bool = false, amount: Double?, minimumZoomLevel: Double = 0.05, maximumZoomLevel: Double = 100.0) -> some View {
        return (amount == nil ?
             (brief ? Text("Actual Size", bundle: .module, comment: "label for brief actual size command") : Text("Actual Size", bundle: .module, comment: "label for non-brief actual size command"))
             : (amount ?? 1.0) > 1.0 ? (brief ? Text("Bigger", bundle: .module, comment: "label for brief zoom in command") : Text("Zoom In", bundle: .module, comment: "label for non-brief zoom in command"))
                 : (brief ? Text("Smaller", bundle: .module, comment: "label for brief zoom out command") : Text("Zoom Out", bundle: .module, comment: "label for non-brief zoom out command")))
            .label(image: amount == nil ? FairSymbol.textformat_superscript : (amount ?? 1.0) > 1.0 ? FairSymbol.textformat_size_larger : FairSymbol.textformat_size_smaller)
                .button {
                    Task {
                        do {
                            try await self.setPageScale(to: amount == nil ? Self.defaultScale : (self.pageScale * (amount ?? 1.0)))
                        } catch {
                            self.reportError(error)
                        }
                    }
                }
    }

    private func setPageScale(to scale: Double) async throws {
        // while WKWebView.pageZoom works on macOS, on iOS it simply zooms the page rather than re-flows it, so we need to instead change the fontSize of the document element
        let newScale = try await webView?.evalJS("scaleText(\(scale))")
        dbg("zooming to:", scale, "result:", newScale)
        if let newScaleString = newScale as? NSString,
            let newScaleAmount = Self.percentParser.number(from: newScaleString as String)?.doubleValue {
            self.pageScale = newScaleAmount
        }
    }

    func applyPageScale() {
        // after loading the view, update the text scale
        Task {
            do {
                dbg("setting page scale:", self.pageScale)
                try await self.setPageScale(to: self.pageScale)
            } catch {
                dbg("error updating page scale:", error)
            }
        }
    }

    override func didFinish(navigation: WKNavigation) {
        super.didFinish(navigation: navigation)
        self.applyPageScale()
        if let targetPosition = self.targetPosition {
            self.targetPosition = nil
            Task {
                do {
                    let _ = try await self.position(targetPosition)
                } catch {
                    self.reportError(error)
                }

            }
        }
    }

    // trim off any anchor elements of an href
    private func trimAnchor(_ href: String) -> String {
        href.split(separator: "#").first?.description ?? href
    }


    /// Loads the selection id from the given document
    /// - Parameters:
    ///   - selection: the selection binding to load; if the selection has changed, the binding will be updated; this is the NXC identifier, nor the manifest identifier
    ///   - offset: whether to load the selection at the given offset
    ///   - document: the document in which to load the selection
    /// - Returns: true if the selection was found and loaded
    @discardableResult func loadSelection(_ selectionBinding: Binding<String??>, offset adjacentOffset: Int, in document: EPUBDocument) -> Bool {

        guard let selection = selectionBinding.wrappedValue,
           let selection = selection,
           let ncx = document.epub.ncx,
           let href = ncx.findHref(forNavPoint: selection) else {
            dbg("no ncx or selection binding:", selectionBinding.wrappedValue ?? nil)
            return false
        }

        if adjacentOffset == 0 {
            // not loading an adjacent item; simply load the href
            dbg("loading ncx href:", href)
            return loadHref(href)
        }

        // when loading an adjacent selection, locate that NCX in the spine and then load the adjacent spine element; this is because the NXC doesn't necessarily list all the items in the book's manifest, just the TOC-worthy elements, so we need to use the spine as the authoritative ordering of the book's manifest elements
        let manifest = document.epub.manifest
        // find the item in the manifest basec on the contect
        guard let item: (key: String, value: (href: String, type: String)) = manifest.first(where: { item in
            // substring search since the NCX href might include a hash
            trimAnchor(href) == trimAnchor(item.value.href)
        }) else {
            dbg("no item id found for href:", href)
            return false
        }

        let spine = document.epub.spine
        guard var index = spine.firstIndex(where: { $0.idref == item.key }) else {
            dbg("no index found for itemid:", item.key)
            return false
        }

        if (index + adjacentOffset) < 0 || (index + adjacentOffset) >= spine.count {
            dbg("offset at index:", index, "is at the edge of the spine bounds:", spine.count)
            return false
        }

        index += adjacentOffset
        let targetSpine = spine[index]
        dbg("moving to spine offset from index:", index, "for itemid:", item.key, targetSpine)

        guard let targetItem = manifest[targetSpine.idref] else {
            dbg("no target item for spine:", targetSpine.idref)
            return false
        }

        dbg("loading ncx adjacentOffset:", adjacentOffset, "href:", targetItem.href)
        if adjacentOffset < 0 {
            // when moving back in chapters, always jump to the end of the scroll
            self.targetPosition = 1.0
        }
        if !loadHref(targetItem.href) {
            dbg("unable to load adjacent href:", targetItem.href)
            return false
        }

        // a map of the trimmed NXC hrefs to the NCXIDs
        let ncxHrefs = ncx.allPoints.map({
            ($0.content.flatMap(trimAnchor), $0.id)
        })
            .dictionary(keyedBy: \.0)
            .compactMapValues(\.1)

        // map of spine IDs to the corresponding manifest href
        let spineTOC: [(manifestID: String, href: String, ncxID: String?)] = spine.compactMap({
            guard let href = manifest[$0.idref]?.href else {
                return nil
            }
            let baseHref = trimAnchor(href)
            return ($0.idref, baseHref, ncxHrefs[baseHref])
        })

        // locate the first prior spine ID that has an NCX entry
        guard let spineIndex = spineTOC.firstIndex(where: { $0.manifestID == targetSpine.idref }) else {
            dbg("unable to locate spine index for spine ID:", targetSpine.idref)
            return false
        }

        guard let ownerTOCItem = spineTOC[0...spineIndex].reversed().first(where: {
            $0.ncxID != nil
        }) else {
            dbg("unable to locate preceeding NCX entry from spine ID:", targetSpine.idref)
            return false
        }

        dbg("setting selection for adjacentOffset:", adjacentOffset, "to:", ownerTOCItem.ncxID)
        if let ncxID = ownerTOCItem.ncxID {
            selectionBinding.wrappedValue = ncxID
        }
        return true
    }

    /// Loads the given href relative to the location of the rootfile in the epub zip.
    /// - Parameters:
    ///   - href: the relative href to load
    ///   - onComplete: a block to execute once the load has completed
    /// - Returns: true if the webView can initiate the load operation
    private func loadHref(_ href: String) -> Bool {
        guard let url = URL(string: "epub:///" + href),
           let webView = self.webView else {
            return false
        }
        webView.load(URLRequest(url: url))
        return true
    }
}
@available(macOS 12.0, iOS 15.0, *)
public struct EPUBView: View {
    @ObservedObject var document: EPUBDocument
    @ObservedObject var bookViewState: BookViewState
    @EnvironmentObject var store: Store
    @Namespace var mainNamespace
    /// The currently selected section
    @Binding var selection: String??

    public var body: some View {
        ZStack {
            bookBody
            controlOverlay
        }
    }

    var controlOverlay: some View {
        HStack {
            Button {
                changePage(by: -1)
            } label: {
                Text("Previous", bundle: .module, comment: "button text for previous page")
                    .label(image: FairSymbol.chevron_left_circle_fill)
            }
            .contentShape(Rectangle().inset(by: -200))
            .keyboardShortcut(.leftArrow, modifiers: [])

            Spacer()

            Button {
                changePage(by: +1)
            } label: {
                Text("Next", bundle: .module, comment: "button text for next page")
                    .label(image: FairSymbol.chevron_right_circle_fill)
            }
            .contentShape(Rectangle().inset(by: -200))
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(Color.accentColor)
        .opacity(0.7)
        .font(Font.largeTitle.bold())
        .buttonStyle(.borderless)
    }

    func changePage(by amount: Int) {
        dbg("change page by:", amount)

        Task {
            do {
                guard let result = try await bookViewState.movePage(by: amount) else {
                    dbg("unable to change page by:", amount)
                    return
                }
                dbg("changed page to:", BookViewState.percentParser.string(from: result as NSNumber))
                if result >= 1.0 {
                    try changeSection(next: true)
                } else if result < 0.0 {
                    try changeSection(next: false)
                }
            } catch {
                bookViewState.reportError(error)
            }
        }
    }

    func changeSection(next: Bool) throws {
        dbg("moving to", next ? "next" : "previous", "section")
        bookViewState.loadSelection($selection, offset: next ? +1 : -1, in: document)
    }

    @ViewBuilder var bookBody: some View {
        webViewBody()
            #if os(macOS) // customizable toolbar on macOS
            .toolbar(id: "EPUBToolbar") {
                ToolbarItem(id: "ZoomOutCommand", placement: .automatic, showsByDefault: true) {
                    bookViewState.textScaleAction(amount: 0.8)
                }
                ToolbarItem(id: "ZoomInCommand", placement: .automatic, showsByDefault: true) {
                    bookViewState.textScaleAction(amount: 1.2)
                }
            }
            #endif
    }

    public func webViewBody() -> some View {
        WebView(state: bookViewState)
    }
}

struct BookReaderView : View {
    @ObservedObject var document: EPUBDocument
    @ObservedObject var bookViewState: BookViewState
    @Binding var selection: String??
//    @GestureState var dragAmount = CGSize.zero
    #if os(iOS)
    //
    @State var showTOCSidebar = false
    @State var showControls = true
    #endif

    var body: some View {
        #if os(macOS)
        NavigationView {
            TOCListView(document: document, selection: $selection)
            bookView
                .navigationTitle(document.epub.title ?? "No Title")
        }
        #elseif os(iOS)
        NavigationView {
            if showTOCSidebar {
                TOCListView(document: document, selection: $selection, action: { selection in
                    dbg("selected:", selection ?? nil)
                    withAnimation {
                        self.selection = selection
                        self.showTOCSidebar = false
                    }
                })
                .listStyle(.sidebar) // seems to not be the default on iOS
                .transition(.slide)
            }

            bookView
                .navigationTitle(document.epub.title ?? "No Title")
                .navigationBarHidden(!showControls)
                .statusBar(hidden: !showControls)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    dbg("tapped on book")
                    withAnimation(.none) {
                        showControls.toggle()
                    }

                }
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        if showControls {
                            bookViewState.textScaleAction(amount: 0.8)
                            Spacer()
                            Text("TOC", bundle: .module, comment: "brief button title for displaying the table of contents")
                                .label(image: FairSymbol.list_bullet)
                                .button {
                                    dbg("toggling TOC")
                                    withAnimation {
                                        self.showTOCSidebar.toggle()
                                    }
                                }
                            Spacer()
                            bookViewState.textScaleAction(amount: 1.2)
                        }
                    }
                }
        }
        #endif
    }

    var bookView: some View {
        EPUBView(document: document, bookViewState: bookViewState, selection: $selection)
            .onChange(of: selection) { selection in
                dbg("selection changed:", selection ?? "")
                bookViewState.loadSelection($selection, offset: 0, in: document)
            }
            .onAppear {
                dbg("appear:", document.epub.title)
                if selection == .none || selection == .some(.none) {
                    let initialNCXID = self.document.epub.ncx?.points.first
                    dbg("loading initial selection:", initialNCXID)
                    DispatchQueue.main.async {
                        self.selection = initialNCXID?.id
                    }
                }
            }
    }
}

/// A selectable list of the table of contents of the book, as defined in the  `.ncx` file.
struct TOCListView : View {
    @ObservedObject var document: EPUBDocument
    /// The selected navPoint ID
    @Binding var selection: String??
    /// The action to perform when an item is selected; this is for platforms (i.e., iOS) where List selection only works with "editable" lists
    var action: ((String??) -> ())? = nil

    var body: some View {
        ScrollViewReader { scrollView in
            List(selection: $selection) {
                Section {
                    ForEach(document.epub.ncx?.toc.array() ?? [], id: \.element.id) { (indices, element) in
                        let text = Text(element.navLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")
                        if let action = action {
                            text
                                .fontWeight(selection == element.id ? .bold : .regular)
                                .button {
                                    action(element.id)
                                }
                                .padding(.leading, .init(indices.count) * 5) // indent
                        } else {
                            // with no action, just display the text
                            text
                                .padding(.leading, .init(indices.count) * 5) // indent
                        }
                    }
                } header: {
                    Text(document.epub.ncx?.title ?? "")
                }
            }
            .onAppear {
                if let selection = selection {
                    scrollView.scrollTo(selection, anchor: .center)
                }
            }
        }
    }
}

/// A scheme handler for loading elements directly from the underlying zip archive.
/// Entries are resolved relative to the location of the OPF file, and the mime type is
/// resolved by a lookup against the manifest.
///
/// https://www.w3.org/publishing/epub32/epub-ocf.html#sec-container-zip
final class EPUBSchemeHandler : NSObject, WKURLSchemeHandler {
    let epub: EPUB

    init(epub: EPUB) {
        self.epub = epub
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        dbg("start urlSchemeTask:", urlSchemeTask.request.url)

        guard let url = urlSchemeTask.request.url else {
            return urlSchemeTask.didFailWithError(AppError("No path for request"))
        }

        // the path of the epub:///filename always starts with "/", which we need to trim
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let entryPath = epub.resolveRelative(path: path)

        dbg("loading path:", entryPath, "relative to", epub.opfPath)

        guard let entry = epub.archive[entryPath] else {
            dbg("could not find entry:", entryPath, "in archive:", epub.archive.map(\.path).sorted())
            return urlSchemeTask.didFailWithError(AppError("Could not find entry: “\(entryPath)”"))
        }

        do {
            let mimeType = epub.manifest.values.first {
                $0.href == path
            }?.type

            dbg("loading:", path, "mimeType:", mimeType)
            let data = try epub.archive.extractData(from: entry)

            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: "utf-8"))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            return urlSchemeTask.didFailWithError(error)
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        dbg("stop urlSchemeTask:", urlSchemeTask.request.url)
    }
}

struct EBookCommands : Commands {
    @FocusedValue(\.document) var document
    @FocusedValue(\.bookViewState) var state

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()

        CommandGroup(after: .sidebar) {
            state?.observing { state in
                state.textScaleAction(amount: nil).keyboardShortcut("0")
                state.textScaleAction(amount: 1.2).keyboardShortcut("+")
                state.textScaleAction(amount: 0.8).keyboardShortcut("-")
            }

            Divider()
        }
    }
}

extension FocusedValues {
    /// The store for the given scene
    var document: EPUBDocument? {
        get { self[DocumentKey.self] }
        set { self[DocumentKey.self] = newValue }
    }

    private struct DocumentKey: FocusedValueKey {
        typealias Value = EPUBDocument
    }
}

extension FocusedValues {
    /// The store for the given scene
    var bookViewState: BookViewState? {
        get { self[BookViewStateKey.self] }
        set { self[BookViewStateKey.self] = newValue }
    }

    private struct BookViewStateKey: FocusedValueKey {
        typealias Value = BookViewState
    }
}

final class EPUBDocument: ReferenceFileDocument {
    static let bundle = Bundle.module

    /// This document can read epub (`org.idpf.epub-container`) files
    static var readableContentTypes: [UTType] = [UTType.epub]

    /// Empty `writableContentTypes` because the content is not editable
    static var writableContentTypes: [UTType] = []

    let epub: EPUB

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let epub = try EPUB(data: data)
        self.epub = epub
    }

    /// Cretae the initial view state for the book
    /// - Parameter pageScale: <#pageScale description#>
    /// - Returns: <#description#>
    @MainActor func createBookViewState() -> BookViewState {
        // possible optimization: the EPUBDocument document initializer loads the zip from the FileWrapper's `fileContents` data, which could mean the whole thing is loaded into memory; we could alternatively load it here from the configuration's `fileURL`, but this means that errors wouldn't be handled by the document's initializer. Profiling should be done on large documents, since it is possible that using mapped reads doesn't wind up loading the whole file in memory anyway

        // let url = file.fileURL

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        prefs.preferredContentMode = .desktop

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs
        config.suppressesIncrementalRendering = true
        //config.limitsNavigationsToAppBoundDomains = true

        // configure loading epub:///file.xhtml directly from the epub zip file
        config.setURLSchemeHandler(EPUBSchemeHandler(epub: epub), forURLScheme: "epub")

        let controller = WKUserContentController()

        config.userContentController = controller

        return BookViewState(initialRequest: nil, configuration: config)
    }

    /// The extract pages from the spine
    func spinePages() -> [URL] {
        epub.spine.compactMap {
            epub.manifest[$0.idref].flatMap {
                //URL(fileURLWithPath: $0.href, relativeTo: extractFolder)
                URL(string: "epub:///" + $0.href)
            }
        }
    }

    func fileWrapper(snapshot: Void, configuration: WriteConfiguration) throws -> FileWrapper {
        throw AppError("Writing not yet supported")
    }

    func snapshot(contentType: UTType) throws -> Void {
        dbg("snapshot:", contentType)
    }
}

public struct AppSettingsView : View {
    @EnvironmentObject var store: Store

    public var body: some View {
        Form {
            Toggle(isOn: $store.smoothScrolling) {
                Text("Smooth scroll pages:", bundle: .module, comment: "toggle preference title for smooth scrolling of pages")
            }
            .toggleStyle(.switch)
        }
        .padding()
    }
}

// MARK: Parochial (package-local) Utilities

extension View {
    /// Alert if the list of errors in not blank
    func alertingError<L: LocalizedError>(_ errorBinding: Binding<[L]>) -> some View {
        alert(isPresented: Binding { !errorBinding.wrappedValue.isEmpty } set: { if $0 == false { errorBinding.wrappedValue.removeLast() } }, error: errorBinding.wrappedValue.last, actions: { _ in
            // TODO: extra actions, like “Report”?
        }, message: { error in
            let err = error as NSError
            if let failureReason = err.failureReason {
                Text(failureReason)
            }
            if let jserror = err.userInfo["WKJavaScriptExceptionMessage"] as? String {
                Text(jserror)
            }
        })
    }
}

/// Is this wise?
extension NSError : LocalizedError {
    public var errorDescription: String? { self.localizedDescription }
    public var failureReason: String? { self.localizedFailureReason }
    // this can result in an infinite loop, e.g., when failing to save a document
    //public var recoverySuggestion: String? { self.localizedRecoverySuggestion }
}



/// Work-in-Progress marker
@available(*, deprecated, message: "work in progress")
internal func wip<T>(_ value: T) -> T { value }

/// Intercept `LocalizedStringKey` constructor and forward it to ``SwiftUI.Text/init(_:bundle)``
/// Otherwise it will default to the main bundle's strings, which is always empty.
@available(*, deprecated, message: "use localized bundle/comment initializer instead")
@usableFromInline internal func Text(_ string: LocalizedStringKey, comment: StaticString? = nil) -> SwiftUI.Text {
    SwiftUI.Text(string, bundle: .module, comment: comment)
}
