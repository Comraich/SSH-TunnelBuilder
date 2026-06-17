# Privacy Policy

**SSH TunnelBuilder**
*Last updated: 17 June 2026*

This Privacy Policy describes how SSH TunnelBuilder ("the app") handles your information when you use it on macOS. The app is published by Comraich ANS ("we", "us") under the Apache License, Version 2.0.

## Summary

**We do not collect, transmit, or store any personal data.**

The app contains no analytics, no telemetry, no advertising identifiers, and no third-party SDKs. Everything the app does happens on your Mac, in your private iCloud account, or on the SSH servers you choose to connect to.

## What the app handles, and where it goes

### Connection profiles (names, hostnames, ports, usernames)

You create connection profiles inside the app. Their non-sensitive fields — the connection name, server hostname, port, username, the local port, the remote server, and the remote port — are stored in the **private CloudKit database** tied to your personal iCloud account. This database is operated by Apple, scoped to you, and is not accessible to us or to anyone else.

If you have iCloud disabled or unavailable, the app falls back to storing the same data locally on the Mac and nothing is synced.

We have no servers and no backend that see this data. There is no account system inside the app.

### Passwords and private keys

Passwords and SSH private keys that you enter are stored in the **macOS Keychain** on the Mac where you entered them. They are never written to iCloud, never transmitted to us, and never leave your device except by being sent to the SSH server you have chosen to connect to — and only at the moment of authentication, only over the encrypted SSH session.

Private-key passphrases are not persisted. They are held in memory only for the duration of a single connection and discarded afterwards.

### Host-key fingerprints

When you first connect to a server, the app records the server's SSH host-key fingerprint (a public, server-published identifier — not a secret) so subsequent connections from any of your Macs can verify they are talking to the same server. The fingerprint is stored in the same private CloudKit database as the connection metadata.

### SSH connections themselves

When you click Connect, the app opens a network connection to the SSH server **you have configured**. We are not party to that connection. The contents of the SSH session — anything you tunnel — flow only between your Mac and the server you chose.

### Encrypted backup files

If you use *File ▸ Export*, the app writes a `.sshtunnels` file containing your connections, encrypted with a passphrase you choose (PBKDF2-HMAC-SHA256, AES-256-GCM). The file is stored wherever you save it. We never see it.

## What we do not do

- We do not run any backend, ad service, or analytics service that the app communicates with.
- We do not embed any third-party SDKs.
- We do not collect crash reports or diagnostics. macOS may offer you the option to share crash reports with Apple; if you accept, those reports go to Apple under Apple's privacy policy, not to us.
- We do not show advertising.
- We do not sell, share, rent, or otherwise use any user data, because we do not have any.

## Your rights under GDPR / UK GDPR

If you are located in the European Economic Area, the United Kingdom, or another jurisdiction that grants similar rights, you have the right to access, rectify, delete, or restrict the processing of any personal data we hold about you. Because we do not collect personal data, there is nothing for us to action under these rights with respect to the app itself.

Personal data you place in your private iCloud database (such as the username field of a connection profile) is governed by Apple's privacy policy and may be exercised through Apple.

## Children's privacy

The app does not collect any data from anyone, including children. The app is rated and intended for general audiences.

## Changes to this policy

If we materially change this policy, the updated text will be published at the same URL with a new "Last updated" date.

## Contact

Questions about this policy can be sent to:

> simon@gale-huset.net
