import SwiftUI
import AVFoundation

/// Records a practice run-through with the Mac's camera and microphone (or the mic alone),
/// saved to ~/Documents/AutoClip/Practice so it can be assessed like a sermon.
@MainActor
final class PracticeRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published var isRecording = false
    @Published var elapsed: Double = 0
    @Published var error: String?
    @Published var ready = false
    @Published var hasCamera = false

    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private var timer: Timer?
    private var started = Date()
    private var cancelled = false
    var onFinished: ((URL) -> Void)?

    nonisolated static var dir: URL {
        let d = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/AutoClip/Practice")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    nonisolated static func isPractice(_ path: String) -> Bool {
        path.hasPrefix(dir.path + "/")
    }

    /// Asks for access and connects the camera (when wanted) and microphone.
    func configure(camera: Bool) async {
        ready = false; error = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = "AutoClip needs the microphone. Allow it in System Settings → Privacy & Security → Microphone."
            return
        }
        let cam = camera ? AVCaptureDevice.default(for: .video) : nil
        if cam != nil, !(await AVCaptureDevice.requestAccess(for: .video)) {
            error = "Camera access is off, so this will record sound only. Allow it in System Settings → Privacy & Security → Camera."
        }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if let cam, AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
           let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
            session.addInput(input)
        }
        guard let mic = AVCaptureDevice.default(for: .audio), let micInput = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(micInput) else {
            session.commitConfiguration()
            error = "No microphone found."
            return
        }
        session.addInput(micInput)
        if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        session.commitConfiguration()
        hasCamera = session.inputs.contains { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) == true }
        let s = session
        await Task.detached { if !s.isRunning { s.startRunning() } }.value
        ready = true
    }

    func start() {
        let f = DateFormatter(); f.dateFormat = "MMM d yyyy 'at' h.mm a"
        let url = Self.dir.appendingPathComponent("Practice – \(f.string(from: Date())).mov")
        cancelled = false
        output.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        started = Date(); elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.elapsed = Date().timeIntervalSince(self.started) }
        }
    }

    func stop() { output.stopRecording() }

    /// Stops without keeping the recording.
    func cancel() {
        if isRecording { cancelled = true; output.stopRecording() }
        shutdown()
    }

    func shutdown() {
        timer?.invalidate(); timer = nil
        let s = session
        Task.detached { if s.isRunning { s.stopRunning() } }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        // A recording can finish "with an error" and still be complete (e.g. disk nearly full)
        let ok = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        Task { @MainActor in
            self.isRecording = false
            self.timer?.invalidate(); self.timer = nil
            if self.cancelled {
                try? FileManager.default.removeItem(at: url)
            } else if ok {
                self.onFinished?(url)
            } else {
                self.error = error?.localizedDescription ?? "The recording stopped unexpectedly."
            }
        }
    }
}

struct PracticeSheet: View {
    let onDone: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var rec = PracticeRecorder()
    @AppStorage("practice_camera") private var useCamera = true
    private let gold = Theme.sand

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Practice run").font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
            Text("Preach it through once before Sunday. When you stop, AutoClip gives you the same report as a sermon: pace, pauses, filler words, voice and the AI coach.")
                .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)

            ZStack {
                Color.black
                if rec.hasCamera {
                    CameraPreview(session: rec.session)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "mic.fill").font(.system(size: 40)).foregroundColor(gold)
                        Text(rec.ready ? "Recording sound only" : "Getting ready…")
                            .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
                    }
                }
                if rec.isRecording {
                    VStack {
                        HStack(spacing: 6) {
                            Circle().fill(Color.red).frame(width: 10, height: 10)
                            Text(fmt(rec.elapsed)).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundColor(.white)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5).background(Color.black.opacity(0.6)).cornerRadius(6)
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .frame(width: 480, height: 270).cornerRadius(10)

            if let e = rec.error {
                Text(e).font(.system(size: 11)).foregroundColor(Color(red: 1, green: 0.55, blue: 0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Toggle("Use camera", isOn: $useCamera).toggleStyle(.switch).tint(Theme.action)
                    .disabled(rec.isRecording)
                    .onChange(of: useCamera) { on in Task { await rec.configure(camera: on) } }
                Spacer()
                Button("Cancel") { rec.cancel(); dismiss() }
                if rec.isRecording {
                    Button { rec.stop() } label: { Label("Stop & assess", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button { rec.start() } label: { Label("Start recording", systemImage: "record.circle") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!rec.ready)
                        .keyboardShortcut(.defaultAction)
                }
            }
            Text("Recordings are saved in Documents › AutoClip › Practice and don't count toward your sermon progress charts.")
                .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.35))
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.surface)
        .task {
            rec.onFinished = { url in
                rec.shutdown()
                dismiss()
                onDone(url)
            }
            await rec.configure(camera: useCamera)
        }
        .onDisappear { if !rec.isRecording { rec.shutdown() } }
    }

    private func fmt(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // Mirror like a selfie camera so moving left looks like moving left
        layer.connection?.automaticallyAdjustsVideoMirroring = false
        layer.connection?.isVideoMirrored = true
        v.layer = layer
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
