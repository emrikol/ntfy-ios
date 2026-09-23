import XCTest
import UserNotifications
@testable import ntfy

final class StoreTests: XCTestCase {
    func testAccessTokenUsesBearerAuthorization() {
        let user = BasicUser(username: "", password: "tk_example")

        XCTAssertTrue(user.isToken)
        XCTAssertEqual(user.toHeader(), "Bearer tk_example")
    }

    func testPasswordUsesBasicAuthorization() {
        let user = BasicUser(username: "derrick", password: "secret")

        XCTAssertFalse(user.isToken)
        XCTAssertEqual(user.toHeader(), "Basic ZGVycmljazpzZWNyZXQ=")
    }

    func testMessageDecodesSequenceID() throws {
        let data = Data(#"{"id":"delete-id","time":1,"event":"message_delete","topic":"alerts","sequence_id":"job-42"}"#.utf8)

        let message = try JSONDecoder().decode(Message.self, from: data)

        XCTAssertEqual(message.sequenceId, "job-42")
    }

    func testBacklogPersistsEveryMessageAndAdvancesCursor() throws {
        let store = Store(inMemory: true)
        let subscription = store.saveSubscription(baseUrl: "https://example.com", topic: "alerts")
        let messages = [
            Message(id: "one", time: 1, event: "message", topic: "alerts", message: "first"),
            Message(id: "two", time: 2, event: "message", topic: "alerts", message: "second"),
            Message(id: "three", time: 3, event: "message", topic: "alerts", message: "third")
        ]

        store.save(notificationsFromMessages: messages, withSubscription: subscription)

        XCTAssertEqual(subscription.lastNotificationId, "three")
        XCTAssertEqual(subscription.notifications?.count, 3)
    }

    func testSequenceUpdateReplacesExistingNotification() throws {
        let store = Store(inMemory: true)
        let subscription = store.saveSubscription(baseUrl: "https://example.com", topic: "alerts")
        let original = Message(
            id: "original-id",
            time: 1,
            event: "message",
            topic: "alerts",
            message: "starting",
            sequenceId: "job-42"
        )
        let update = Message(
            id: "update-id",
            time: 2,
            event: "message",
            topic: "alerts",
            message: "complete",
            sequenceId: "job-42"
        )

        store.save(notificationsFromMessages: [original, update], withSubscription: subscription)

        let notifications = try XCTUnwrap(subscription.notifications?.allObjects as? [ntfy.Notification])
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications[0].id, "update-id")
        XCTAssertEqual(notifications[0].message, "complete")
        XCTAssertEqual(notifications[0].sequenceId, "job-42")
    }

    func testDeleteEventRemovesMessageWithoutCreatingBlankRow() throws {
        let store = Store(inMemory: true)
        let subscription = store.saveSubscription(baseUrl: "https://example.com", topic: "alerts")
        let original = Message(
            id: "original-id",
            time: 1,
            event: "message",
            topic: "alerts",
            message: "temporary",
            sequenceId: "job-42"
        )
        let deletion = Message(
            id: "delete-id",
            time: 2,
            event: "message_delete",
            topic: "alerts",
            sequenceId: "job-42"
        )

        store.save(notificationsFromMessages: [original, deletion], withSubscription: subscription)

        XCTAssertEqual(subscription.notifications?.count, 0)
        XCTAssertEqual(subscription.lastNotificationId, "delete-id")
    }

    func testSequenceUpdateIsScopedToItsSubscription() throws {
        let store = Store(inMemory: true)
        let first = store.saveSubscription(baseUrl: "https://example.com", topic: "first")
        let second = store.saveSubscription(baseUrl: "https://example.com", topic: "second")
        store.save(notificationsFromMessages: [
            Message(id: "first-id", time: 1, event: "message", topic: "first", message: "first", sequenceId: "shared"),
        ], withSubscription: first)
        store.save(notificationsFromMessages: [
            Message(id: "second-id", time: 1, event: "message", topic: "second", message: "old", sequenceId: "shared"),
            Message(id: "second-update", time: 2, event: "message", topic: "second", message: "new", sequenceId: "shared"),
        ], withSubscription: second)

        let firstNotifications = try XCTUnwrap(first.notifications?.allObjects as? [ntfy.Notification])
        let secondNotifications = try XCTUnwrap(second.notifications?.allObjects as? [ntfy.Notification])
        XCTAssertEqual(firstNotifications.map(\.id), ["first-id"])
        XCTAssertEqual(secondNotifications.map(\.id), ["second-update"])
    }

    func testMinimumAndLowPrioritiesAreSilent() {
        for priority: Int16 in [1, 2] {
            let content = UNMutableNotificationContent()
            let message = Message(id: "id-\(priority)", time: 1, event: "message", topic: "alerts", priority: priority)

            content.modify(message: message, baseUrl: "https://example.com")

            XCTAssertNil(content.sound)
            XCTAssertEqual(content.interruptionLevel, .passive)
        }
    }
}
