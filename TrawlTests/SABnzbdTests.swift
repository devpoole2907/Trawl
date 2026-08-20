import Testing
import Foundation
@testable import Trawl

@Suite("SABnzbd Decoding Tests")
struct SABnzbdDecodingTests {
    private static let decoder = JSONDecoder()

    // MARK: - Queue

    @Test("Queue Envelope Decodes With Mixed Scalar Types")
    func queueEnvelopeDecodesWithMixedScalarTypes() throws {
        let json = """
        {
          "queue": {
            "status": "Downloading",
            "paused": false,
            "paused_all": false,
            "speed": "1.2 M",
            "kbpersec": "1234.5",
            "size": "4.5 GB",
            "sizeleft": "2.1 GB",
            "mb": 4500,
            "mbleft": "2100",
            "timeleft": "0:12:34",
            "noofslots": 2,
            "noofslots_total": "2",
            "start": 0,
            "limit": 200,
            "version": "4.3.0",
            "slots": [
              {
                "nzo_id": "SABnzbd_nzo_abc123",
                "filename": "Some.Release.Name",
                "status": "Downloading",
                "index": 0,
                "priority": "Normal",
                "cat": "tv",
                "script": "none",
                "time_added": 1700000000,
                "timeleft": "0:12:34",
                "percentage": "45.5",
                "mb": "1024",
                "mbleft": "512",
                "mbmissing": 0,
                "size": "1 GB",
                "sizeleft": "512 MB",
                "labels": [],
                "direct_unpack": "3/8"
              }
            ]
          }
        }
        """
        let envelope = try Self.decoder.decode(SABnzbdQueueEnvelope.self, from: Data(json.utf8))
        let queue = envelope.queue

        #expect(queue.status == "Downloading")
        #expect(queue.paused == false)
        #expect(queue.kilobytesPerSecond == 1234.5)
        #expect(queue.megabytesLeft == 2100)
        #expect(queue.noOfSlots == 2)
        #expect(queue.noOfSlotsTotal == 2)
        #expect(queue.slots.count == 1)

        let slot = try #require(queue.slots.first)
        #expect(slot.nzoID == "SABnzbd_nzo_abc123")
        #expect(slot.category == "tv")
        #expect(slot.percentageValue == 45.5)
        #expect(slot.progress == 0.455)
        #expect(slot.megabytes == 1024)
    }

    @Test("Queue Slot Falls Back To Defaults For Missing Fields")
    func queueSlotFallsBackToDefaults() throws {
        let json = """
        { "nzo_id": "abc", "filename": "X" }
        """
        let slot = try Self.decoder.decode(SABnzbdQueueSlot.self, from: Data(json.utf8))
        #expect(slot.status == "Unknown")
        #expect(slot.priority == "Normal")
        #expect(slot.size == "0 B")
        #expect(slot.labels.isEmpty)
    }

    // MARK: - History

    @Test("History Envelope Decodes Slots")
    func historyEnvelopeDecodesSlots() throws {
        let json = """
        {
          "history": {
            "noofslots": 1,
            "ppslots": 0,
            "day_size": "1 GB",
            "week_size": "5 GB",
            "month_size": "20 GB",
            "total_size": "100 GB",
            "last_history_update": 1700000500,
            "version": "4.3.0",
            "slots": [
              {
                "nzo_id": "SABnzbd_nzo_def456",
                "name": "Completed.Release",
                "status": "Completed",
                "cat": "movies",
                "size": "2 GB",
                "bytes": "2147483648",
                "downloaded": 2147483648,
                "time_added": 1699999000,
                "completed": 1700000000,
                "download_time": 600,
                "postproc_time": 30,
                "fail_message": "",
                "storage": "/downloads/movies/Completed.Release",
                "loaded": false,
                "archive": false,
                "pp": "3",
                "stage_log": []
              }
            ]
          }
        }
        """
        let envelope = try Self.decoder.decode(SABnzbdHistoryEnvelope.self, from: Data(json.utf8))
        let history = try #require(envelope.history)

        #expect(history.lastHistoryUpdate == 1700000500)
        #expect(history.slots.count == 1)

        let slot = try #require(history.slots.first)
        #expect(slot.nzoID == "SABnzbd_nzo_def456")
        #expect(slot.bytes == 2_147_483_648)
        #expect(slot.normalizedStatus == .completed)
        #expect(slot.normalizedStatus.isTerminal)
        #expect(slot.progress == 1)
    }

    @Test("History Envelope Decodes False Shape As Nil")
    func historyEnvelopeDecodesFalseShapeAsNil() throws {
        let json = #"{ "history": false }"#
        let envelope = try Self.decoder.decode(SABnzbdHistoryEnvelope.self, from: Data(json.utf8))
        #expect(envelope.history == nil)
    }

    @Test("Post-Processing History Slot Is Active, Not Terminal")
    func postProcessingHistorySlotIsActiveNotTerminal() throws {
        let json = """
        {
          "nzo_id": "SABnzbd_nzo_ppslot",
          "name": "Unpacking.Now",
          "status": "Extracting",
          "size": "3 GB",
          "bytes": 3000000000,
          "downloaded": 3000000000,
          "completed": 0,
          "fail_message": "",
          "loaded": true,
          "archive": false,
          "stage_log": []
        }
        """
        let slot = try Self.decoder.decode(SABnzbdHistorySlot.self, from: Data(json.utf8))
        let job = SABnzbdJob(historySlot: slot)

        #expect(slot.normalizedStatus == .unpacking)
        #expect(slot.normalizedStatus.isActive)
        #expect(!slot.normalizedStatus.isTerminal)
        #expect(job.isPostProcessing)
        #expect(job.source == .history)
    }

    @Test("Failed History Slot Surfaces Fail Message")
    func failedHistorySlotSurfacesFailMessage() throws {
        let json = """
        {
          "nzo_id": "SABnzbd_nzo_failed",
          "name": "Broken.Release",
          "status": "Failed",
          "size": "0 B",
          "bytes": 0,
          "downloaded": 0,
          "completed": 1700000900,
          "fail_message": "Unpacking failed, archive files missing",
          "loaded": false,
          "archive": true,
          "stage_log": []
        }
        """
        let slot = try Self.decoder.decode(SABnzbdHistorySlot.self, from: Data(json.utf8))
        let job = SABnzbdJob(historySlot: slot)

        #expect(slot.normalizedStatus == .failed)
        #expect(slot.normalizedStatus.isTerminal)
        #expect(!job.isPostProcessing)
        #expect(job.failureMessage == "Unpacking failed, archive files missing")
    }

    // MARK: - Status normalization

    @Test("Normalized Status Maps Raw SABnzbd Values", arguments: [
        ("queued", SABnzbdNormalizedStatus.waiting),
        ("Grabbing", .waiting),
        ("Downloading", .downloading),
        ("Paused", .paused),
        ("Verifying", .repairing),
        ("Repairing", .repairing),
        ("Extracting", .unpacking),
        ("Unpacking", .unpacking),
        ("Moving", .processing),
        ("Running", .processing),
        ("Completed", .completed),
        ("Failed", .failed)
    ])
    func normalizedStatusMapsRawValues(raw: String, expected: SABnzbdNormalizedStatus) {
        #expect(SABnzbdNormalizedStatus(rawValue: raw) == expected)
    }

    @Test("Normalized Status Falls Back To Unknown")
    func normalizedStatusFallsBackToUnknown() {
        let status = SABnzbdNormalizedStatus(rawValue: "SomeNewSABStatus")
        guard case .unknown(let raw) = status else {
            Issue.record("Expected .unknown case")
            return
        }
        #expect(raw == "SomeNewSABStatus")
        #expect(!status.isActive)
        #expect(!status.isTerminal)
    }

    // MARK: - Authentication and command envelopes

    @Test("Authentication Envelope Decodes Auth Kind", arguments: [
        ("apikey", SABnzbdAuthentication.apiKey),
        ("nzbkey", .nzbKey),
        ("badkey", .badKey)
    ])
    func authenticationEnvelopeDecodesAuthKind(raw: String, expected: SABnzbdAuthentication) throws {
        let json = #"{ "auth": "\#(raw)" }"#
        let envelope = try Self.decoder.decode(SABnzbdAuthenticationEnvelope.self, from: Data(json.utf8))
        #expect(envelope.authentication == expected)
    }

    @Test("Command Response Decodes Error Shape")
    func commandResponseDecodesErrorShape() throws {
        let json = """
        { "status": false, "error": "NZB not found" }
        """
        let response = try Self.decoder.decode(SABnzbdCommandResponse.self, from: Data(json.utf8))
        #expect(response.status == false)
        #expect(response.error == "NZB not found")
        #expect(response.nzoIDs.isEmpty)
    }

    @Test("Command Response Decodes Success Shape With Nzo IDs")
    func commandResponseDecodesSuccessShapeWithNzoIDs() throws {
        let json = """
        { "status": true, "nzo_ids": ["SABnzbd_nzo_1", "SABnzbd_nzo_2"] }
        """
        let response = try Self.decoder.decode(SABnzbdCommandResponse.self, from: Data(json.utf8))
        #expect(response.status == true)
        #expect(response.nzoIDs == ["SABnzbd_nzo_1", "SABnzbd_nzo_2"])
    }

    // MARK: - API error descriptions

    @Test("API Error Extracts Message From JSON Body")
    func apiErrorExtractsMessageFromJSONBody() throws {
        let body = #"{ "status": false, "error": "API Key Incorrect" }"#
        let error = SABnzbdAPIError.http(status: 200, body: body)
        let description = try #require(error.errorDescription)
        #expect(description.contains("API Key Incorrect"))
    }

    @Test("API Error Falls Back To Raw Body When Not JSON")
    func apiErrorFallsBackToRawBodyWhenNotJSON() throws {
        let error = SABnzbdAPIError.http(status: 500, body: "Internal Server Error")
        let description = try #require(error.errorDescription)
        #expect(description.contains("Internal Server Error"))
    }

    @Test("Insufficient API Key Error Has Descriptive Message")
    func insufficientAPIKeyErrorHasDescriptiveMessage() throws {
        let description = try #require(SABnzbdAPIError.insufficientAPIKey.errorDescription)
        #expect(description.contains("full SABnzbd API key"))
    }
}
