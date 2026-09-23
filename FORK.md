# emrikol ntfy iOS fork

This repository uses two long-lived branches:

- `main` mirrors `binwiederhier/ntfy-ios` and is the base for upstream pull requests.
- `private` contains the stable bundle identifiers and signing configuration for Derrick's privately installed app.

The private app uses:

- App bundle: `com.emrikol.ntfy`
- Notification service extension: `com.emrikol.ntfy.ntfyNSE`
- App group: `group.com.emrikol.ntfy`
- Apple team: `3T9RX85H44`

The app has the ordinary time-sensitive-notification entitlement. Critical-alert controls stay hidden because Apple has not granted the separate critical-alert entitlement to this app ID. Standard and time-sensitive notification sounds continue to work.

## Push delivery

The private branch removes Firebase. The app registers its APNs token and hashed subscriptions with a direct APNs relay at `/_ntfy_apns/v1/registrations` on each authenticated self-hosted server. The relay accepts stock ntfy `poll_request` forwarding and sends the wake-up notification directly to APNs.

Registration state is durable: removing the final subscription or deleting a user queues an authenticated empty registration until the relay confirms it. Credentials are stored in the shared iOS Keychain, not Core Data. Both ntfy username/password credentials and revocable access tokens are supported.

The notification extension fetches the complete backlog after an APNs wake-up so messages received while the phone was offline are not lost. It also handles message updates/deletes, clears notification-center entries requested by actions, and keeps priorities 1 and 2 silent as specified by ntfy.

## Local secrets

Never commit any of these files:

- `AuthKey_*.p8`

The APNs key belongs only on the private relay host. It is never embedded in the app or committed to this repository.

## Bringing in upstream changes

Update the clean branch first:

```sh
git switch main
git fetch upstream
git merge --ff-only upstream/main
git push origin main
```

Then merge the update into the private app branch:

```sh
git switch private
git merge main
git push origin private
```

Create upstreamable bug-fix branches from `main`, not `private`, so private signing changes do not enter pull requests.
