import AVFoundation
import HaishinKit
import Photos
import UIKit
import VideoToolbox

final class IngestViewController: UIViewController {
    @IBOutlet private weak var currentFPSLabel: UILabel!
    @IBOutlet private weak var publishButton: UIButton!
    @IBOutlet private weak var pauseButton: UIButton!
    @IBOutlet private weak var videoBitrateLabel: UILabel!
    @IBOutlet private weak var videoBitrateSlider: UISlider!
    @IBOutlet private weak var audioBitrateLabel: UILabel!
    @IBOutlet private weak var zoomSlider: UISlider!
    @IBOutlet private weak var audioBitrateSlider: UISlider!
    @IBOutlet private weak var fpsControl: UISegmentedControl!
    @IBOutlet private weak var effectSegmentControl: UISegmentedControl!
    @IBOutlet private weak var audioDevicePicker: UIPickerView!
    @IBOutlet private weak var audioMonoStereoSegmentCOntrol: UISegmentedControl!
    
    @ScreenActor
    private var currentEffect: (any VideoEffect)?
    private var currentPosition: AVCaptureDevice.Position = .back
    private var retryCount: Int = 0
    private var preferedStereo = false
    private let netStreamSwitcher: HKStreamSwitcher = .init()
    private lazy var mixer = MediaMixer()
    private lazy var audioCapture: AudioCapture = {
        let audioCapture = AudioCapture()
        audioCapture.delegate = self
        return audioCapture
    }()
    @ScreenActor
    private var videoScreenObject = VideoTrackScreenObject()
    
    @ScreenActor
    private var imageScreenObject = ImageScreenObject()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        Task {
            // If you want to use the multi-camera feature, please make sure stream.isMultiCamSessionEnabled = true. Before attachCamera or attachAudio.
            // mixer.isMultiCamSessionEnabled = true
            //            if let orientation = DeviceUtil.videoOrientation(by: UIApplication.shared.statusBarOrientation) {
            //                await mixer.setVideoOrientation(orientation)
            //            }

            var videoMixerSettings = await mixer.videoMixerSettings
            videoMixerSettings.mode = .offscreen
            await mixer.setVideoMixerSettings(videoMixerSettings)
            await mixer.setFrameRate(60)
            await mixer.setSessionPreset(AVCaptureSession.Preset.hd1920x1080)
            await mixer.setVideoOrientation(.landscapeRight)
            await netStreamSwitcher.setPreference(Preference.default)
            if let stream = await netStreamSwitcher.stream {
                await mixer.addOutput(stream)
                if let view = view as? (any HKStreamOutput) {
                    await stream.addOutput(view)
                }
                
                let videoSettings = VideoCodecSettings(
                    videoSize: .init(width: 1920, height: 1080),
                    bitRate: 1920 * 1080,
                    profileLevel: kVTProfileLevel_H264_Baseline_AutoLevel as String
                )
                
                await stream.setVideoSettings(videoSettings)
            }
        }
        
        Task { @ScreenActor in
            let imageURL = URL(fileURLWithPath: Bundle.main.path(forResource: "overlay", ofType: "png") ?? "")
            if let provider = CGDataProvider(url: imageURL as CFURL) {
                imageScreenObject.cgImage = CGImage(
                    pngDataProviderSource: provider,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent
                )
            } else {
                logger.info("no image")
            }
            imageScreenObject.size = .init(width: 1920, height: 1080)
            
            await mixer.screen.size = .init(width: 1920, height: 1080)
            await mixer.screen.backgroundColor = UIColor.black.cgColor
            try? await mixer.screen.addChild(imageScreenObject)
        }
        
        videoBitrateSlider?.value = Float(VideoCodecSettings.default.bitRate) / 1000
        audioBitrateSlider?.value = Float(AudioCodecSettings.default.bitRate) / 1000
    }
    
    override func viewWillAppear(_ animated: Bool) {
        logger.info("viewWillAppear")
        super.viewWillAppear(animated)
        
        Task {
            let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            try? await mixer.attachVideo(front, track: 0) { videoUnit in
                videoUnit.isVideoMirrored = true
                videoUnit.preferredVideoStabilizationMode = .standard
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(on(_:)), name: UIDevice.orientationDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didInterruptionNotification(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didRouteChangeNotification(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        logger.info("viewWillDisappear")
        super.viewWillDisappear(animated)
        Task {
            await netStreamSwitcher.close()
            try? await mixer.attachAudio(nil)
            try? await mixer.attachVideo(nil, track: 0)
        }
        // swiftlint:disable:next notification_center_detachment
        NotificationCenter.default.removeObserver(self)
    }

    @IBAction func rotateCamera(_ sender: UIButton) {
        logger.info("rotateCamera")
        
        Task {
            let position: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
            try? await mixer.attachVideo(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)) { videoUnit in
                videoUnit.isVideoMirrored = position == .front
            }
            currentPosition = position
        }
    }
    
    @IBAction func toggleTorch(_ sender: UIButton) {
        Task {
            let isTorchEnabled = await mixer.isTorchEnabled
            await mixer.setTorchEnabled(!isTorchEnabled)
        }
    }
    
    @IBAction func on(slider: UISlider) {
        if slider == audioBitrateSlider {
            Task {
                guard let stream = await netStreamSwitcher.stream else {
                    return
                }
                audioBitrateLabel?.text = "audio \(Int(slider.value))/kbps"
                var audioSettings = await stream.audioSettings
                audioSettings.bitRate = Int(slider.value * 1000)
                await stream.setAudioSettings(audioSettings)
            }
        }
        if slider == videoBitrateSlider {
            Task {
                guard let stream = await netStreamSwitcher.stream else {
                    return
                }
                videoBitrateLabel?.text = "video \(Int(slider.value))/kbps"
                var videoSettings = await stream.videoSettings
                videoSettings.bitRate = Int(slider.value * 1000)
                await stream.setVideoSettings(videoSettings)
            }
        }
        if slider == zoomSlider {
            let zoomFactor = CGFloat(slider.value)
            Task {
                try await mixer.configuration(video: 0) { unit in
                    guard let device = unit.device else {
                        return
                    }
                    try device.lockForConfiguration()
                    device.ramp(toVideoZoomFactor: zoomFactor, withRate: 5.0)
                    device.unlockForConfiguration()
                }
            }
        }
    }
    
    @IBAction func on(pause: UIButton) {
        Task {
            if let stream = await netStreamSwitcher.stream as? RTMPStream {
                _ = try? await stream.pause(true)
            }
        }
    }
    
    @IBAction func on(close: UIButton) {
        self.dismiss(animated: true, completion: nil)
    }
    
    @IBAction func on(publish: UIButton) {
        Task {
            if publish.isSelected {
                UIApplication.shared.isIdleTimerDisabled = false
                await netStreamSwitcher.close()
                publish.setTitle("●", for: [])
            } else {
                UIApplication.shared.isIdleTimerDisabled = true
                await netStreamSwitcher.open(.ingest)
                publish.setTitle("■", for: [])
            }
            publish.isSelected.toggle()
        }
    }
    
    func tapScreen(_ gesture: UIGestureRecognizer) {
        if let gestureView = gesture.view, gesture.state == .ended {
            let touchPoint: CGPoint = gesture.location(in: gestureView)
            let pointOfInterest = CGPoint(x: touchPoint.x / gestureView.bounds.size.width, y: touchPoint.y / gestureView.bounds.size.height)
            Task {
                try await mixer.configuration(video: 0) { unit in
                    guard let device = unit.device else {
                        return
                    }
                    try device.lockForConfiguration()
                    device.focusPointOfInterest = pointOfInterest
                    device.focusMode = .continuousAutoFocus
                    device.unlockForConfiguration()
                }
            }
        }
    }
    
    private func setEnabledPreferredInputBuiltInMic(_ isEnabled: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            if isEnabled {
                guard
                    let availableInputs = session.availableInputs,
                    let builtInMicInput = availableInputs.first(where: { $0.portType == .builtInMic }) else {
                    return
                }
                try session.setPreferredInput(builtInMicInput)
            } else {
                try session.setPreferredInput(nil)
            }
        } catch {
        }
    }
    
    @IBAction private func onFPSValueChanged(_ segment: UISegmentedControl) {
        Task {
            switch segment.selectedSegmentIndex {
            case 0:
                await mixer.setFrameRate(15)
            case 1:
                await mixer.setFrameRate(30)
            case 2:
                await mixer.setFrameRate(60)
            default:
                break
            }
        }
    }
    
    @IBAction private func onEffectValueChanged(_ segment: UISegmentedControl) {
        Task { @ScreenActor in
            if let currentEffect {
                _ = await mixer.screen.unregisterVideoEffect(currentEffect)
            }
            switch await segment.selectedSegmentIndex {
            case 1:
                currentEffect = MonochromeEffect()
                _ = await mixer.screen.registerVideoEffect(currentEffect!)
            case 2:
                currentEffect = PronamaEffect()
                _ = await mixer.screen.registerVideoEffect(currentEffect!)
            default:
                break
            }
        }
    }
    
    @IBAction private func onStereoMonoChanged(_ segment: UISegmentedControl) {
        switch segment.selectedSegmentIndex {
        case 0:
            preferedStereo = false
        case 1:
            preferedStereo = true
            pickerView(audioDevicePicker, didSelectRow: audioDevicePicker.selectedRow(inComponent: 0), inComponent: 0)
        default:
            break
        }
    }
    
    @objc
    private func didInterruptionNotification(_ notification: Notification) {
        logger.info(notification)
    }
    
    @objc
    private func didRouteChangeNotification(_ notification: Notification) {
        logger.info(notification)
        if AVAudioSession.sharedInstance().inputDataSources?.isEmpty == true {
            setEnabledPreferredInputBuiltInMic(false)
            audioMonoStereoSegmentCOntrol.isHidden = true
            audioDevicePicker.isHidden = true
        } else {
            setEnabledPreferredInputBuiltInMic(true)
            audioMonoStereoSegmentCOntrol.isHidden = false
            audioDevicePicker.isHidden = false
        }
        audioDevicePicker.reloadAllComponents()
        Task {
            if DeviceUtil.isHeadphoneDisconnected(notification) {
                await mixer.setMonitoringEnabled(false)
            } else {
                await mixer.setMonitoringEnabled(DeviceUtil.isHeadphoneConnected())
            }
        }
    }
    
    @objc
    private func on(_ notification: Notification) {
        guard let orientation = DeviceUtil.videoOrientation(by: UIApplication.shared.statusBarOrientation) else {
            return
        }
        Task {
            await mixer.setVideoOrientation(orientation)
        }
    }
}

extension IngestViewController: AudioCaptureDelegate {
    // MARK: AudioCaptureDelegate
    nonisolated func audioCapture(_ audioCapture: AudioCapture, buffer: AVAudioBuffer, time: AVAudioTime) {
        Task { await mixer.append(buffer, when: time) }
    }
}

extension IngestViewController: UIPickerViewDelegate {
    // MARK: UIPickerViewDelegate
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        let session = AVAudioSession.sharedInstance()
        guard let preferredInput = session.preferredInput,
              let newDataSource = preferredInput.dataSources?[row],
              let supportedPolarPatterns = newDataSource.supportedPolarPatterns else {
            return
        }
        do {
            if #available(iOS 14.0, *) {
                if preferedStereo && supportedPolarPatterns.contains(.stereo) {
                    try newDataSource.setPreferredPolarPattern(.stereo)
                    logger.info("stereo")
                } else {
                    audioMonoStereoSegmentCOntrol.selectedSegmentIndex = 0
                    logger.info("mono")
                }
            }
            try preferredInput.setPreferredDataSource(newDataSource)
        } catch {
            logger.warn("can't set supported setPreferredDataSource")
        }
        Task {
            try? await mixer.attachAudio(AVCaptureDevice.default(for: .audio))
        }
    }
}

extension IngestViewController: UIPickerViewDataSource {
    // MARK: UIPickerViewDataSource
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }
    
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return AVAudioSession.sharedInstance().preferredInput?.dataSources?.count ?? 0
    }
    
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        return AVAudioSession.sharedInstance().preferredInput?.dataSources?[row].dataSourceName ?? ""
    }
}
