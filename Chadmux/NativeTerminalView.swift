import SwiftTerm
import UIKit

/// Finger movement is scroll-wheel input; selection is local iOS selection.
/// Never translate a swipe into a mouse-button drag or cursor-key sequence.
final class NativeTerminalView: TerminalView, UIGestureRecognizerDelegate {
    var selectionBounds: ((CGPoint) async -> CGRect?)?
    private var selectionRequest = UUID()
    var remoteScroll: ((Int, CGPoint) -> Void)?
    var inputAvailable = false { didSet { if !inputAvailable { stopMomentum(); dismissSelection() } } }
    private var fingerPan: UIPanGestureRecognizer?
    private var momentum: CADisplayLink?
    private var velocity: CGFloat = 0
    private var remainder: CGFloat = 0
    private var anchor = CGPoint.zero
    private var pausedRecognizers: [(UIGestureRecognizer,Bool)] = []
    private var selectionView: TerminalSelectionView?
    private var lastFrame: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame:frame)
        // SwiftTerm's local selection/Copy writes to UIPasteboard. Remote app
        // mouse selection must not swallow those gestures.
        allowMouseReporting = false
        inputAccessoryView = nil // The app already supplies its terminal key row.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-scroll-live-fixture") {
            cursorStyleChanged(source:getTerminal(),newStyle:.steadyBlock)
        }
        #endif
        let pan = ScrollPanRecognizer(target:self,action:#selector(scrollFinger(_:)))
        pan.onTouchDown = { [weak self] in self?.stopMomentum() }
        pan.maximumNumberOfTouches = 1; pan.delegate = self
        fingerPan = pan
        addGestureRecognizer(pan)
        let press = UILongPressGestureRecognizer(target:self,action:#selector(selectText(_:)))
        press.minimumPressDuration = 0.45
        for recognizer in gestureRecognizers ?? [] where recognizer !== pan {
            if recognizer is UILongPressGestureRecognizer { removeGestureRecognizer(recognizer) }
            else if recognizer is UIPanGestureRecognizer { recognizer.isEnabled = false }
            else if let tap = recognizer as? UITapGestureRecognizer {
                tap.require(toFail:press)
                if tap.numberOfTapsRequired > 1 {
                    tap.removeTarget(nil,action:nil)
                    tap.addTarget(self,action:#selector(selectWithTap(_:)))
                }
            }
        }
        addGestureRecognizer(press)
    }
    #if DEBUG
    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        // Cursor blinking keeps XCTest's animation-idle detector busy in tmux
        // copy mode. Only the disposable UI fixture uses a steady caret.
        super.cursorStyleChanged(source:source, newStyle:ProcessInfo.processInfo.arguments.contains("--native-scroll-live-fixture") ? .steadyBlock : newStyle)
    }
    #endif
    required init?(coder:NSCoder) { fatalError("Use init(frame:)") }
    override func addGestureRecognizer(_ recognizer: UIGestureRecognizer) {
        if let press = recognizer as? UILongPressGestureRecognizer {
            press.removeTarget(nil,action:nil)
            press.addTarget(self,action:#selector(selectText(_:)))
        }
        super.addGestureRecognizer(recognizer)
        if let pan = fingerPan, recognizer !== pan, recognizer is UIPanGestureRecognizer { recognizer.isEnabled = false }
        if selectionView != nil {
            pausedRecognizers.append((recognizer,recognizer.isEnabled)); recognizer.isEnabled = false
        }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === fingerPan else { return true }
        stopMomentum()
        // Native selection handle drags belong to SwiftTerm while selecting.
        return inputAvailable && selectionView == nil
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { stopMomentum(); dismissSelection() } }
    @objc private func selectText(_ gesture:UILongPressGestureRecognizer) {
        guard gesture.state == .began, selectionView == nil else { return }
        beginSelection(at:gesture.location(in:self))
    }
    @objc private func selectWithTap(_ gesture:UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        beginSelection(at:gesture.location(in:self))
    }
    func visibleText() -> String {
        let terminal = getTerminal(), top = getTerminal().getTopVisibleRow()
        return terminal.getText(start:Position(col:0,row:top),end:Position(col:terminal.cols,row:top+terminal.rows-1))
    }
    func beginSelection(at point:CGPoint) {
        guard selectionView == nil else { return }
        stopMomentum()
        let token = UUID(); selectionRequest = token
        if let selectionBounds {
            Task { [weak self] in
                guard let rect = await selectionBounds(point), let self,
                      self.selectionRequest == token, self.inputAvailable else { return }
                self.presentSelection(at:point,in:rect)
            }
        } else { presentSelection(at:point,in:bounds) }
    }
    private func presentSelection(at point:CGPoint,in rect:CGRect) {
        let selection = TerminalSelectionView(frame:rect)
        let terminal = getTerminal(), frame = getOptimalFrameSize()
        let cw = frame.width/CGFloat(terminal.cols), ch = frame.height/CGFloat(terminal.rows)
        let x = max(0,Int((rect.minX-contentOffset.x)/cw)), y = max(0,Int((rect.minY-contentOffset.y)/ch))
        let endX = min(terminal.cols,Int((rect.maxX-contentOffset.x)/cw+0.01))
        let endY = min(terminal.rows,Int((rect.maxY-contentOffset.y)/ch+0.01))
        selection.backgroundColor = nativeBackgroundColor
        selection.textColor = nativeForegroundColor
        selection.font = font
        selection.textContainerInset = .zero
        selection.textContainer.lineFragmentPadding = 0
        selection.isEditable = false; selection.isSelectable = true
        if rect == bounds { selection.text = visibleText() }
        else {
            selection.text = (y..<max(y,endY)).compactMap {
                terminal.getLine(row:$0)?.translateToString(trimRight:true,startCol:x,endCol:endX,skipNullCellsFollowingWide:true)
            }.joined(separator:"\n")
        }
        selection.accessibilityIdentifier = "terminal.selection"
        selection.onDismiss = { [weak self] in self?.dismissSelection() }
        selection.inputView = UIView(frame:.zero)
        selection.inputAccessoryView = nil
        selectionView = selection
        isAccessibilityElement = false
        pausedRecognizers = (gestureRecognizers ?? []).map { ($0,$0.isEnabled) }
        for (recognizer,_) in pausedRecognizers { recognizer.isEnabled = false }
        addSubview(selection)
        selection.becomeFirstResponder()
        selection.layoutIfNeeded()
        selection.layoutManager.ensureLayout(for:selection.textContainer)
        if let position = selection.closestPosition(to:CGPoint(x:point.x-rect.minX,y:point.y-rect.minY)),
           let range = selection.tokenizer.rangeEnclosingPosition(position,with:.word,inDirection:UITextDirection(rawValue:UITextStorageDirection.forward.rawValue)) {
            selection.selectedTextRange = range
            DispatchQueue.main.async {
                UIMenuController.shared.showMenu(from:selection,rect:selection.firstRect(for:range))
            }
        }
    }
    func dismissSelection() {
        selectionRequest = UUID()
        selectionView?.resignFirstResponder()
        selectionView?.removeFromSuperview(); selectionView = nil
        isAccessibilityElement = true
        for (recognizer,enabled) in pausedRecognizers { recognizer.isEnabled = enabled }
        pausedRecognizers = []
        clearSelection()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the frozen selection stable if keyboard/rotation resizes the terminal.
        if let selectionView {
            var rect = selectionView.frame
            rect.size.width = min(rect.width,bounds.width)
            rect.size.height = min(rect.height,bounds.height)
            rect.origin.x = max(bounds.minX,min(rect.minX,bounds.maxX-rect.width))
            rect.origin.y = max(bounds.minY,min(rect.minY,bounds.maxY-rect.height))
            selectionView.frame = rect
        }
    }
    @objc private func scrollFinger(_ gesture:UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopMomentum(); remainder = 0
            let location = gesture.location(in:self)
            anchor = CGPoint(x:location.x-contentOffset.x,y:location.y-contentOffset.y)
            consume(gesture.translation(in:self).y)
            gesture.setTranslation(.zero,in:self)
        case .changed:
            consume(gesture.translation(in:self).y)
            gesture.setTranslation(.zero,in:self)
        case .ended:
            consume(gesture.translation(in:self).y)
            // A short viewport (landscape/keyboard) must still accept a short
            // deliberate swipe even when it is smaller than one wheel tick.
            if abs(remainder) >= 8 {
                remoteScroll?(remainder > 0 ? 1 : -1,anchor)
                remainder = 0
            }
            velocity = max(-2500,min(2500,gesture.velocity(in:self).y))
            if abs(velocity) > 80 {
                let link = CADisplayLink(target:self,selector:#selector(coast(_:)))
                momentum = link; lastFrame = 0
                link.add(to:.main,forMode:.common)
            }
        default: stopMomentum()
        }
    }
    @objc private func coast(_ link:CADisplayLink) {
        guard inputAvailable, selectionView == nil, !hasActiveSelection else { stopMomentum(); return }
        let dt = lastFrame == 0 ? 1.0/60 : min(0.05,link.timestamp-lastFrame)
        lastFrame = link.timestamp
        consume(velocity*dt)
        // A flick glides longer; touch-down still cancels it immediately.
        velocity *= pow(0.96,dt*60)
        if abs(velocity) < 30 { stopMomentum() }
    }
    func stopMomentum() { momentum?.invalidate(); momentum = nil; velocity = 0; remainder = 0 }
    private func consume(_ delta:CGFloat) {
        guard inputAvailable else { return }
        let rows = max(1,getTerminal().rows)
        let rowHeight = max(1,getOptimalFrameSize().height/CGFloat(rows))
        // Wheel consumers differ: tmux typically moves several rows, while
        // apps may move only one. Send a tick per 1.5 rendered row heights
        // so an ordinary swipe covers useful history without repeated swipes.
        let threshold = rowHeight*1.5
        remainder += delta
        let ticks = max(-8,min(8,Int(remainder/threshold)))
        guard ticks != 0 else { return }
        remainder -= CGFloat(ticks)*threshold
        remoteScroll?(ticks,anchor)
    }
}

extension NativeTerminalView: TerminalScreen {
    var contentOrigin: CGPoint { contentOffset }
    /// Black with JetBrains Mono at the terminal's usual 12 pt, as on the Mac.
    func useChadmuxColors() {
        nativeBackgroundColor = .black; nativeForegroundColor = .white
        setFonts(normal: TerminalFont.font(.regular, size: 12), bold: TerminalFont.font(.bold, size: 12),
                 italic: TerminalFont.font(.italic, size: 12), boldItalic: TerminalFont.font(.boldItalic, size: 12))
    }
}

/// UIKit owns selection handles, magnification, word boundaries and Copy.
/// Text lives only in this view and the clipboard after an explicit Copy.
private final class TerminalSelectionView: UITextView {
    // Do not let a read-only snapshot inherit the terminal's Paste action.
    override var next: UIResponder? { window }
    var onDismiss: (() -> Void)?
    override init(frame:CGRect,textContainer:NSTextContainer? = nil) {
        super.init(frame:frame,textContainer:textContainer)
        let close = UIButton(type:.system)
        close.setImage(UIImage(systemName:"xmark.circle.fill"),for:.normal)
        close.accessibilityLabel = "Close text selection"
        close.addTarget(self,action:#selector(closeSelection),for:.touchUpInside)
        close.backgroundColor = .black; close.layer.cornerRadius = 22
        addSubview(close)
        close.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo:frameLayoutGuide.leadingAnchor,constant:8),
            close.bottomAnchor.constraint(equalTo:frameLayoutGuide.bottomAnchor,constant:-8),
            close.widthAnchor.constraint(equalToConstant:44),close.heightAnchor.constraint(equalToConstant:44)])
    }
    required init?(coder:NSCoder) { fatalError("Use init(frame:)") }
    @objc private func closeSelection() { onDismiss?() }
    override func copy(_ sender:Any?) { super.copy(sender); onDismiss?() }
}

private final class ScrollPanRecognizer: UIPanGestureRecognizer {
    var onTouchDown: (() -> Void)?
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent) {
        onTouchDown?()
        super.touchesBegan(touches,with:event)
    }
}
