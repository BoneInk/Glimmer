import AppKit

/// Static, cancellable off-main composition; no timer, player or desktop assignment.
@MainActor
final class SceneWallpaperCanvasView: NSView {
    private var inspection: SceneWallpaperInspection?
    private var image: CGImage?
    private var requestedSize: CGSize = .zero
    private var generation = 0
    private var renderTask: Task<Void, Never>?
    private(set) var lastError: String?

    func setInspection(_ value: SceneWallpaperInspection) throws {
        cancelRender();image=nil;requestedSize = .zero
        guard value.isRenderableSubset else {
            inspection=nil;lastError="Scene contains unsupported features or incomplete dependencies.";needsDisplay=true
            throw SceneWallpaperFailure(message:lastError!)
        }
        inspection=value;lastError=nil;needsDisplay=true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {cancelRender();requestedSize = .zero}
        else {needsDisplay=true}
    }
    private func cancelRender() {generation+=1;renderTask?.cancel();renderTask=nil}
    private func requestRender(_ inspection:SceneWallpaperInspection,size:CGSize) {
        guard requestedSize != size || (image == nil && renderTask == nil && lastError == nil) else {return}
        cancelRender();requestedSize=size
        let ticket=generation
        let work=Task.detached(priority:.userInitiated) {try SceneWallpaperRenderer.render(inspection:inspection,pixelSize:size)}
        renderTask=Task { [weak self] in
            let result=await withTaskCancellationHandler {await work.result} onCancel:{work.cancel()}
            guard let self,!Task.isCancelled,self.generation==ticket else {return}
            self.renderTask=nil
            switch result {
            case .success(let image):self.image=image;self.lastError=nil
            case .failure(let error):self.image=nil;self.lastError=error.localizedDescription
            }
            self.needsDisplay=true
        }
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.black.setFill();bounds.fill()
        guard let inspection,bounds.width>0,bounds.height>0 else {return}
        requestRender(inspection,size:convertToBacking(bounds).size)
        if let image,let context=NSGraphicsContext.current?.cgContext {context.draw(image,in:bounds)}
        else if let lastError {
            (lastError as NSString).draw(in:bounds.insetBy(dx:12,dy:12),withAttributes:[.foregroundColor:NSColor.white,.font:NSFont.systemFont(ofSize:12)])
        }
    }
    deinit {renderTask?.cancel()}
}
