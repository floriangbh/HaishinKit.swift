//
//  LocalStream.swift
//  HaishinKit
//
//  Created by Florian Gabach on 19/05/2020.
//  Copyright © 2020 Shogo Endo. All rights reserved.
//
import Foundation

open class LocalStream: NetStream {
    var resourceName: String?

    open private(set) var recording: Bool = false {
        didSet {
            guard oldValue != recording else {
                return
            }

            if oldValue {
                // was recording
                #if os(iOS)
                    mixer.videoIO.screen?.stopRunning()
                #endif
                mixer.audioIO.encoder.stopRunning()
                mixer.videoIO.encoder.stopRunning()
                mixer.recorder.stopRunning()
            }

            if recording {
                #if os(iOS)
                    mixer.videoIO.screen?.startRunning()
                #endif
                mixer.startRunning()
                mixer.audioIO.encoder.startRunning()
                mixer.videoIO.encoder.startRunning()
                mixer.recorder.fileName = resourceName
                mixer.recorder.startRunning()
            }
        }
    }

    open var paused = false {
        didSet {
            lockQueue.async {
                self.mixer.audioIO.encoder.muted = self.paused
                self.mixer.videoIO.encoder.muted = self.paused
            }
        }
    }

    deinit {
        mixer.stopRunning()
    }

    open func record(_ name: String?) {
        lockQueue.async {
            guard let name: String = name else {
                if self.recording {
                    self.recording = false
                }
                return
            }

            self.resourceName = name
            self.recording = true
        }
    }

    open func close() {
        if !recording {
            return
        }
        record(nil)
        lockQueue.sync {
            self.recording = false
        }
    }
}
