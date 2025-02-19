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
import FairKit

final class BookReaderState : WebViewState {
    @AppStorage("smoothScrolling") var smoothScrolling = true
    @AppStorage("leadingTapAdvances") var leadingTapAdvances = false

    @AppStorage("hmargin") var hmargin: Int = 40
    @AppStorage("vmargin") var vmargin: Int = 20

    @AppStorage("pageScale") var pageScale: Double = BookReaderState.defaultScale {
        didSet {
            // TODO: make this @SceneStorage? We'd need to move it into a view…
            self.resetUserScripts(webView: self.webView)
        }
    }

    /// The most recent tap region as reported by the canvas
    @Published var touchRegion: Double? = nil

    /// The percentage progress in the current section
    @Published var progress: Double = 0.0

    /// The total width in the section
    @Published var sectionWidth: Double = 0.0

    @Published var showTOCSidebar = false

    /// The target position to jump to once the book has loaded
    private var targetPosition: Double? = nil

    #if os(iOS)
    static let defaultScale = 4.0
    #else
    static let defaultScale = 2.0
    #endif

    #if os(iOS)
    var scrollDelegate: ScrollViewDelegate?

    /// A delegate that updates the progress within the current section whenever the view is scrolled.
    /// This is in addition to the updating that happens as a result of the `movePage()` invocations.
    class ScrollViewDelegate : NSObject, UIScrollViewDelegate {
        unowned var state: BookReaderState

        init(_ state: BookReaderState) {
            self.state = state
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            dbg(scrollView.contentOffset, scrollView.contentSize)
            // update the progress states whenever we scroll
            if scrollView.contentSize.width > 0.0 {
                state.progress = scrollView.contentOffset.x / scrollView.contentSize.width
            }
        }
    }
    #endif

    override func createWebView() -> WebEngineView {
        let webView = super.createWebView()
        #if os(iOS)
        let scrollView = webView.scrollView

        // allow swiping to settle on page boundries
        scrollView.isPagingEnabled = true

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false

        scrollView.pinchGestureRecognizer?.isEnabled = false
        scrollView.bounces = false

        self.scrollDelegate = ScrollViewDelegate(self)
        scrollView.delegate = scrollDelegate
        #endif

        resetUserScripts(webView: webView)
        return webView
    }

    enum MessageType : String, CaseIterable {
        case log
        case click
        case touchstart
        case touchcancel
        case touchleave
        case touchend
    }

    class MessageHandler : NSObject, WKScriptMessageHandlerWithReply {
        weak var state: BookReaderState!

        init(_ state: BookReaderState) {
            self.state = state
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
            guard let type = MessageType(rawValue: message.name) else {
                return dbg("invalid message name:", message.name)
            }

            guard let msg = message.body as? NSDictionary else {
                return dbg("message was invalid:", message.body)
            }

            state.handle(type: type, message: msg)
        }
    }

    private func handle(type: MessageType, message msg: NSDictionary) {
        switch type {
        case .log:
            dbg("log", type.rawValue, "message:", msg)
        case .click:
            dbg("click", type.rawValue, "info:", msg)
        case .touchstart, .touchend:
            dbg(type.rawValue, "info:", msg)
            if let clientWidth = msg["clientWidth"] as? Double,
               let pageX = msg["pageX"] as? Double {
                let selectionCount = (msg["selectionCount"] as? Int) ?? 0
                if selectionCount == 0 { // only move pages if we don't have any text selected (so we can expand the selection by dragging); a tap in the view will clear the selection automatically
                    handleTouch(pageX: pageX, clientWidth: clientWidth, clientX: msg["clientX"] as? Double, start: type == .touchstart)
                }
            }
        case .touchcancel, .touchleave:
            dbg("touchcancel", type.rawValue, "info:", msg)
            break
        }
    }

    private var lastTouchStart: Date? = nil
    private var lastPageX: Double? = nil
    private var lastClientX: Double? = nil

    private func handleTouch(pageX: Double, clientWidth: Double, clientX: Double?, start: Bool) {
        dbg("touch:", pageX, "clientX:", clientX ?? lastClientX, "/", clientWidth, "start:", start)
        if start == true {
            self.lastTouchStart = Date()
            self.lastPageX = pageX
            self.lastClientX = clientX
        } else {
            defer {
                // touch-end resets all properties
                self.lastPageX = nil
                self.lastClientX = nil
                self.lastTouchStart = nil
            }

            if let lastPageX = self.lastPageX,
               let clientX = self.lastClientX,
               let lastTouchStart = self.lastTouchStart,
               lastTouchStart > Date(timeIntervalSinceNow: -0.2) {
                dbg("pageX:", pageX, "lastPageX:", lastPageX)
                if lastPageX == pageX { // i.e., not a swipe
                    self.touchRegion = clientX / clientWidth
                }
            }
        }
    }

    func resetUserScripts(webView: WKWebView?) {
        guard let controller = webView?.configuration.userContentController else {
            return dbg("no userContentController")
        }

        func evt(_ type: MessageType) -> String {
            type.rawValue
        }

        #if os(macOS)
        // on macOS we don't have access to the WKWebView's NSScrollView and so cannot interface with the native scrolling mechanism, so we hide the horizontal scroll bars
        let overflowX = "hidden"
        #elseif os(iOS)
        // on iOS we can access the UIScrollView and so can interface with the scrolling gestures
        let overflowX = "visible"
        #endif

        let script = """
            function postMessage(name, info) {
                let handler = window.webkit.messageHandlers[name];
                if (typeof handler === 'undefined' && name != "log") {
                    log("message handler" + name + " is not set");
                } else {
                    // need to round-trip info to pass to message handlers
                    let info2 = JSON.parse(JSON.stringify(info));
                    handler.postMessage(info2);
                }
            };

            function log(msg) {
                postMessage('\(evt(.log))', { 'message' : msg });
            };

            log("start user script");

            function touchEvent(event) {
                // touchend doesn't have touches element
                let touch = event.touches[0] ?? event;

                return {
                    'identifier': touch.identifier,
                    'pageX': event.pageX,
                    'pageY': event.pageY,
                    'clientX': touch.clientX,
                    'clientY': touch.clientY,
                    'screenX': touch.screenX,
                    'screenY': touch.screenY,
                    'clientWidth': document.documentElement.clientWidth,
                    'clientHeight': document.documentElement.clientHeight,
                    'selectionCount': window.getSelection().rangeCount,
                };
            };

            window.addEventListener('\(evt(.click))', function(event) {
                postMessage('\(evt(.click))', touchEvent(event));
            }, false);

            window.addEventListener('\(evt(.touchstart))', function(event) {
                postMessage('\(evt(.touchstart))', touchEvent(event));
            }, false);

            window.addEventListener('\(evt(.touchcancel))', function(event) {
                postMessage('\(evt(.touchcancel))', touchEvent(event));
            }, false);

            window.addEventListener('\(evt(.touchleave))', function(event) {
                postMessage('\(evt(.touchleave))', touchEvent(event));
            }, false);

            window.addEventListener('\(evt(.touchend))', function(event) {
                postMessage('\(evt(.touchend))', touchEvent(event));
            }, false);

            var meta = document.createElement('meta');
            meta.name = 'viewport';

            meta.content = 'user-scalable=no';
            var head = document.getElementsByTagName('head')[0];
            head.appendChild(meta);

            var bs = document.body.style;

            //document.documentElement.style.overflowY = 'hidden';

            //bs.overflow = 'hidden';
            bs.overflowX = '\(overflowX)';
            bs.overflowY = 'hidden';

            //bs.scrollSnapType = 'x mandatory';
            //bs.scrollSnapPointsX = 'repeat(800px)';

            //bs.verticalAlign = 'middle';

            bs.height = '96vh';
            bs.columnWidth = '100vh';
            bs.webkitLineBoxContain = 'block glyphs replaced';

            bs.marginTop = '\(vmargin)px';
            bs.marginBottom = '\(vmargin)px';

            bs.marginLeft = '\(hmargin)px';
            bs.marginRight = '\(hmargin)px';

            bs.columnGap = '\(hmargin*2)px';

            bs.overflowWrap = 'break-word';
            bs.hyphens = 'auto';
            // webkitHyphens is also needed or else pages won't hyphenate
            bs.webkitHyphens = 'auto';

            //bs.display = 'flex';
            //bs.flexDirection = 'column';

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

                var p = 0.0;
                if (pos < 0.0) {
                    p = -1; // less than one indicates before beginning
                } else if (pos > (totalWidth - (screenWidth / 2.0))) {
                    p = 1.1; // more than one indicates past end
                } else {
                    p = Math.max(0.0, Math.min(1.0, pos / totalWidth));
                }

                return { "pos": p, "x": window.scrollX, "y": window.scrollY, "width": document.documentElement.scrollWidth, "height": document.documentElement.scrollHeight }
            };

            // with no argument, returns the current scroll position;
            // with an argument, jumps to the given position and snaps to the nearest
            // page boundry
            function position(amount) {
                if (typeof amount === 'number') {
                    let pos = document.documentElement.scrollWidth * amount;
                    window.scrollTo({ 'left': pos, 'behavior': 'instant' });
                    return movePage(0, false); // snap to nearest page
                }
                return { }
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

                // position(position()); // snap to nearest page boundry on resize // TODO: need to know the position before we resize; so just snap to the page instead
                movePage(0, false);

                //log("window resized");

                // for some reason this seems to get reset after a resize
                //document.body.style.overflow = 'hidden';
            };

            window.onresize = handleResize;

            log("complete user script");
            """

        // user scripts cannot be removed piecemeal, so just remove everything and re-add
        controller.removeAllUserScripts()
        controller.removeAllScriptMessageHandlers()

        for messageType in MessageType.allCases {
            controller.addScriptMessageHandler(MessageHandler(self), contentWorld: .defaultClient, name: messageType.rawValue)
        }

        dbg("adding user script handler")

        controller.addUserScript(WKUserScript(source: script, injectionTime: WKUserScriptInjectionTime.atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
    }

    @MainActor @discardableResult func movePage(by amount: Int, smooth: Bool? = nil) async throws -> Double? {
        guard let webView = self.webView else {
            throw AppError("No book render host installed")
        }

        return handleNavigation(try await webView.evalJS("movePage(\(amount), \(smooth ?? smoothScrolling))"))
    }

    @MainActor func handleNavigation(_ result: Any) -> Double? {
        dbg("result:", result)
        if let navigation = result as? NSDictionary {
            if let pos = navigation["pos"] as? Double,
               //let x = navigation["x"] as? Double,
               let width = navigation["width"] as? Double {
                //let prog = width * pos
                self.sectionWidth = width
                self.progress = pos > 1.0 ? 0.0 : pos
                dbg("set progress to:", self.progress)
                return pos
            }
        }

        return nil
    }

    /// Sets the position in the current section to the given value
    /// - Parameter target: the target position, from 0.0–1.0, or nil to simply query the position
    /// - Returns: the current position in the current section
    @MainActor @discardableResult func position(_ target: Double? = nil) async throws -> Double? {
        guard let webView = self.webView else {
            throw AppError("No book render host installed")
        }

        return handleNavigation(try await webView.evalJS("position(\(target?.description ?? ""))"))
    }

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
                            await self.reportError(error)
                        }
                    }
                }
    }

    @MainActor private func setPageScale(to scale: Double) async throws {
        // while WKWebView.pageZoom works on macOS, on iOS it simply zooms the page rather than re-flows it, so we need to instead change the fontSize of the document element
        let newScale = try await webView?.evalJS("scaleText(\(scale))")
        dbg("zooming to:", scale, "result:", newScale)
        if let newScaleString = newScale as? NSString,
            let newScaleAmount = percentParser.number(from: newScaleString as String)?.doubleValue {
            self.pageScale = newScaleAmount
        }
    }

    @MainActor func applyPageScale() {
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
        Task {
            await self.applyPageScale()
            if let targetPosition = self.targetPosition {
                do {
                    dbg("jumping to targetPosition:", targetPosition)
                    let _ = try await self.position(targetPosition)
                } catch {
                    await self.reportError(error)
                }
            }
            self.targetPosition = nil
        }
    }

    /// Loads the selection id from the given document
    /// - Parameters:
    ///   - selection: the selection binding to load; if the selection has changed, the binding will be updated; this is the NXC identifier, nor the manifest identifier
    ///   - position: the percentage in the section to load
    ///   - adjacent: whether to load the selection at the given offset
    ///   - document: the document in which to load the selection
    /// - Returns: true if the selection was found and loaded
    @discardableResult func loadSelection(_ sectionBinding: Binding<String??>, position: Double? = nil, adjacent adjacentOffset: Int = 0, in document: EPUBDocument) -> Bool {

        guard let selection = sectionBinding.wrappedValue,
           let selection = selection,
           let ncx = document.epub.ncx,
              let href = ncx.findNavpoint(id: selection)?.content else {
            dbg("no ncx or selection binding:", sectionBinding.wrappedValue ?? nil)
            return false
        }

        if let position = position {
            // if we are trying to load from a target position, jump to it
            if self.targetPosition == nil {
                self.targetPosition = position
            }
        } else if adjacentOffset < 0 {
            // when moving back in sections, always jump to the end of the scroll view
            self.targetPosition = 1.0
        }

        if adjacentOffset == 0 {
            // not loading an adjacent item; simply load the href
            dbg("loading ncx href:", href)
            return loadHref(href)
        }

        let actualHref = self.webView?.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? href

        guard let ncxID = document.epub.navigateToSection(of: actualHref, offset: adjacentOffset, loadHref: loadHref) else {
            dbg("failed to navigate to href:", actualHref)
            return false
        }

        dbg("setting selection for adjacentOffset:", adjacentOffset, "to:", ncxID)
        sectionBinding.wrappedValue = ncxID
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

// trim off any anchor elements of an href
private func trimAnchor(_ href: String) -> String {
    href.split(separator: "#").first?.description ?? href
}

extension EPUB {
    /// Calculate the ajcacent visible section to the given href. It does this by scanning the spine for the given href, moving to the adjacent section, and then returns the ncxID of the resulting page.
    /// - Parameters:
    ///   - actualHref: <#actualHref description#>
    ///   - adjacentOffset: <#adjacentOffset description#>
    ///   - loadHref: <#loadHref description#>
    /// - Returns: <#description#>
    func navigateToSection(of href: String, offset adjacentOffset: Int, loadHref: (String) -> Bool) -> String? {
        // when loading an adjacent selection, locate that NCX in the spine and then load the adjacent spine element; this is because the NXC doesn't necessarily list all the items in the book's manifest, just the TOC-worthy elements, so we need to use the spine as the authoritative ordering of the book's manifest elements

        // find the item in the manifest basec on the context
        let items: [(key: String, value: (href: String, type: String))] = opf.manifest.filter({ item in
            // substring search since the NCX href might include a hash
            trimAnchor(href) == trimAnchor(item.value.href)
        })

        dbg("found items for href:", href, items)
        guard let item = items.first else {
            dbg("no item id found for href:", href)
            return nil
        }

        let spine = opf.spine
        //dbg("scanning for key:", item.key, "in:", spine.map(\.idref))

        guard var index = spine.lastIndex(where: { $0.idref == item.key }) else {
            dbg("no index found for itemid:", item.key)
            return nil
        }

        if (index + adjacentOffset) < 0 || (index + adjacentOffset) >= spine.count {
            dbg("offset at index:", index, "is at the edge of the spine bounds:", spine.count)
            return nil
        }

        index += adjacentOffset
        let targetSpine = spine[index]
        dbg("moving to spine offset from index:", index, "for itemid:", item.key, targetSpine)

        guard let targetItem = opf.manifest[targetSpine.idref] else {
            dbg("no target item for spine:", targetSpine.idref)
            return nil
        }

        dbg("loading ncx adjacentOffset:", adjacentOffset, "href:", targetItem.href)
        if !loadHref(targetItem.href) {
            dbg("unable to load adjacent href:", targetItem.href)
            return nil
        }

        guard let ncx = ncx else {
            dbg("no table of contents for href:", targetItem.href)
            return nil
        }

        // a map of the trimmed NXC hrefs to the NCXIDs
        let ncxHrefs = ncx.allPoints.map({
            ($0.content.flatMap(trimAnchor), $0.id)
        })
            .dictionary(keyedBy: \.0)
            .compactMapValues(\.1)

        // map of spine IDs to the corresponding manifest href
        let spineTOC: [(manifestID: String, href: String, ncxID: String?)] = spine.compactMap({
            guard let href = opf.manifest[$0.idref]?.href else {
                return nil
            }
            let baseHref = trimAnchor(href)
            return ($0.idref, baseHref, ncxHrefs[baseHref])
        })

        // locate the first prior spine ID that has an NCX entry
        guard let spineIndex = spineTOC.firstIndex(where: { $0.manifestID == targetSpine.idref }) else {
            dbg("unable to locate spine index for spine ID:", targetSpine.idref)
            return nil
        }

        guard let ownerTOCItem = spineTOC[0...spineIndex].reversed().first(where: {
            $0.ncxID != nil
        }) else {
            dbg("unable to locate preceeding NCX entry from spine ID:", targetSpine.idref)
            return nil
        }

        return ownerTOCItem.ncxID
    }
}

// MARK: Parochial (package-local) Utilities

extension View {
    /// Alert if the list of errors in not blank
    func alertingError(_ errorBinding: Binding<[NSError]>) -> some View {
        let isPresented = Binding { !errorBinding.wrappedValue.isEmpty } set: { if $0 == false { errorBinding.wrappedValue.removeLast() } }

        return alert(errorBinding.wrappedValue.last?.localizedFailureReason ?? errorBinding.wrappedValue.last?.localizedDescription ?? NSLocalizedString("Error", bundle: .module, comment: "generic error message title"), isPresented: isPresented, presenting: errorBinding.wrappedValue.last) { error in
            // TODO: extra actions, like “Report”?

        } message: { error in
            if let localizedDescription = error.localizedDescription {
                Text(localizedDescription)
            }
            if let failureReason = error.localizedFailureReason {
                Text(failureReason)
            }
            if let jserror = error.userInfo["WKJavaScriptExceptionMessage"] as? String {
                Text(jserror)
            }
        }
    }
}

/// Is this wise?
//extension NSError : LocalizedError {
//    public var errorDescription: String? { self.localizedDescription }
//    public var failureReason: String? { self.localizedFailureReason }
//    // this can result in an infinite loop, e.g., when failing to save a document
//    //public var recoverySuggestion: String? { self.localizedRecoverySuggestion }
//}


func percent(_ number: Double?) -> String? {
    guard let number = number else {
        return nil
    }
    return percentParser.string(from: number as NSNumber)
}

fileprivate let percentParser: NumberFormatter = {
    let fmt = NumberFormatter()
    fmt.numberStyle = .percent
    return fmt
}()


/// Work-in-Progress marker
@available(*, deprecated, message: "work in progress")
internal func wip<T>(_ value: T) -> T { value }

/// Intercept `LocalizedStringKey` constructor and forward it to ``SwiftUI.Text/init(_:bundle)``
/// Otherwise it will default to the main bundle's strings, which is always empty.
@available(*, deprecated, message: "use localized bundle/comment initializer instead")
@usableFromInline internal func Text(_ string: LocalizedStringKey, comment: StaticString? = nil) -> SwiftUI.Text {
    SwiftUI.Text(string, bundle: .module, comment: comment)
}
