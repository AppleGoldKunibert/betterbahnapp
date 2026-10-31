import Foundation
import Testing
@testable import BetterBahnKit

struct TrainTurnaroundTests {
    @Test func readsPreviousAndNextTrains() throws {
        let json = """
        {"previousJourneys":[{"journeyID":"a","journeyRelation":{"startTime":"2026-10-31T13:05:00Z","startEvaNumber":"8000191","startAdministrationID":"80","startCategory":"ICE","startJourneyNumber":567},"wagonIdentificationNumber":21}],
         "nextJourneys":[{"journeyID":"b","journeyRelation":{"startTime":"2026-11-01T04:34:00Z","startEvaNumber":"8098160","startAdministrationID":"80","startCategory":"ICE","startJourneyNumber":1501},"wagonIdentificationNumber":21},
                         {"journeyID":"c","journeyRelation":{"startCategory":"ICE","startJourneyNumber":1501},"wagonIdentificationNumber":22}]}
        """
        let response = try JSONDecoder().decode(BahnExpertClient.TurnaroundResponse.self, from: Data(json.utf8))
        let turnaround = BahnExpertClient.turnaround(from: response)
        #expect(turnaround.previous.map(\.name) == ["ICE 567"])
        #expect(turnaround.next.map(\.name) == ["ICE 1501"])
    }

    @Test func emptyAnswerIsEmpty() throws {
        let response = try JSONDecoder().decode(BahnExpertClient.TurnaroundResponse.self, from: Data("{}".utf8))
        #expect(BahnExpertClient.turnaround(from: response).isEmpty)
    }

    @Test func asksWithTheFirstOpenCoachOfEachOwnTrainset() throws {
        let json = """
        {"isRealtime":true,"sequence":{"groups":[
          {"journeyNumber":1000,"coaches":[{"evn":"1","closed":true},{"evn":"2","closed":false}]},
          {"journeyNumber":999,"coaches":[{"evn":"9"}]},
          {"journeyNumber":1000,"coaches":[{"evn":"3"}]}]}}
        """
        let response = try JSONDecoder().decode(BahnExpertClient.SequenceResponse.self, from: Data(json.utf8))
        #expect(BahnExpertClient.vehicleIds(of: response, journeyNumber: 1000) == ["2", "3"])
    }
}
