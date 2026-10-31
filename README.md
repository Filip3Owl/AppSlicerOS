<h1 align="center">
  <img src="docs/assets/logo.svg" alt="AppSlicerOS" width="720">
</h1>

<p align="center">
  <strong>Embedded machine learning to anticipate memory pressure on macOS.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-in%20development-E3242B" alt="Status: in development">
  <img src="https://img.shields.io/badge/macOS-13%2B-7D8590" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/Swift-6-7D8590" alt="Swift 6">
</p>

<p align="center">
  <strong>English</strong> | <a href="README.pt-BR.md">Português (Brasil)</a>
</p>

> [!WARNING]
> AppSlicerOS is in early development. The project currently contains only the
> machine learning library. There is no app to install yet.

## Table of contents

- [About](#about)
- [Principles](#principles)
- [Architecture](#architecture)
- [Getting started](#getting-started)
- [Using the library](#using-the-library)
- [Project structure](#project-structure)
- [Roadmap](#roadmap)
- [Development workflow](#development-workflow)
- [License](#license)

## About

macOS already manages system memory, and no app can take over that job. That is why
AppSlicerOS does not promise to "clean" your RAM, a practice that tends to discard
useful cache and slow the Mac down.

The goal is different: learn how each Mac is used, predict periods of memory pressure,
and help the user act before the system slows down. A real-time dashboard will make
all of this visible.

## Principles

- **Local processing:** usage data and training stay on the Mac.
- **Low overhead:** the target is under 100 MB of RAM and under 2% average CPU.
- **User control:** no app will be closed without authorization.
- **Measurable results:** success means less time under pressure and less swap growth,
  not more free memory.

## Architecture

The diagram shows the planned system. Only the forecasting model is implemented so far.

```mermaid
flowchart LR
    A[Metrics collector] --> B[Forecasting model]
    A --> C[Dashboard]
    B --> C
    B --> D[Recommendations]
    D --> E{User authorizes?}
    E -- Yes --> F[Action on the app]
```

The `AppSlicerML` library is written in pure Swift, with no external dependencies:

| Component | Purpose |
| --- | --- |
| `RunningStandardizer` | Normalizes metrics incrementally using Welford's algorithm. |
| `OnlineLogisticRegression` | Classifies with logistic regression, learning from each sample with AdaGrad. |
| `EWMAAnomalyDetector` | Detects sudden deviations in a metric using an exponential moving average. |
| `PressureForecaster` | Estimates the probability of elevated pressure within a time horizon. |
| `ForecasterStore` | Saves and restores the model so learning continues across restarts. |

## Getting started

### Prerequisites

- macOS 13 or later
- Swift 6, included with the Command Line Tools (Xcode is not required)

So far, the project has only been built and tested on an Intel Mac running macOS 15.

### Installation

```sh
git clone https://github.com/Filip3Owl/AppSlicerOS.git
cd AppSlicerOS
swift build
```

### Tests

```sh
swift test
```

The tests use synthetic data. They validate the model's learning and rules, but they
do not measure its accuracy in real use.

## Using the library

Pass in a memory sample at each reading. The model learns on its own as the outcome of
each sample becomes known.

```swift
import AppSlicerML
import Foundation

var forecaster = PressureForecaster()

let sample = MemorySample(
    timestamp: Date().timeIntervalSince1970,
    usedFraction: 0.72,
    compressedFraction: 0.18,
    swapUsedFraction: 0.35,
    pageoutsPerSecond: 12,
    isPressureElevated: false
)

if let probability = forecaster.observe(sample) {
    print("Chance of elevated pressure: \(Int(probability * 100))%")
} else {
    print("The model is still learning.")
}
```

The default horizon is 10 minutes. Forecasts are published only after 20 examples of
each class, with and without elevated pressure. Both values can be changed in
`PressureForecaster.Configuration`.

### Saving the model

Use `ForecasterStore` to keep what the model has learned between runs:

```swift
import AppSlicerML

let store = ForecasterStore(fileURL: try ForecasterStore.defaultFileURL())
var forecaster = try store.load(configuration: PressureForecaster.Configuration())

// Observe samples, then save periodically and before quitting.
try store.save(forecaster)
```

The model is stored in `~/Library/Application Support/AppSlicerOS/`, readable only by
the current user. If the file is missing, corrupted, or from an incompatible version
or configuration, the model starts over.

## Project structure

```text
AppSlicerOS/
├── Package.swift              # Swift package definition
├── README.md                  # Documentation in English
├── README.pt-BR.md            # Documentation in Brazilian Portuguese
├── Sources/
│   └── AppSlicerML/           # Machine learning algorithms
├── Tests/
│   └── AppSlicerMLTests/      # Automated tests
└── docs/
    └── assets/                # Logo and other images
```

## Roadmap

This is an initial roadmap and may change as the project produces real data.

### Phase 1: machine learning core

- [x] Incremental metric normalization
- [x] Logistic regression with online learning
- [x] Anomaly detector
- [x] Memory pressure forecasting
- [x] Tests with synthetic data
- [x] Save and restore the model on disk

### Phase 2: metrics collection

- [ ] Read system pressure, compression, swap, and paging
- [ ] Measure memory consumption per app
- [ ] Store history locally in SQLite
- [ ] Define a data retention policy

### Phase 3: real-time dashboard

- [ ] Build the menu bar app with SwiftUI
- [ ] Display real-time charts with Swift Charts
- [ ] List the apps using the most memory
- [ ] Show the model's forecast and learning status

### Phase 4: validation with real data

- [ ] Compare the model against fixed-threshold alerts
- [ ] Measure forecast accuracy in real use
- [ ] Verify the RAM and CPU targets

### Phase 5: recommendations and actions

- [ ] Identify idle apps that can be closed
- [ ] Send alerts ahead of pressure spikes
- [ ] Close apps upon user confirmation
- [ ] Allow automation only for authorized apps
- [ ] Block actions on system processes

### Phase 6: distribution

- [x] Set up continuous integration with GitHub Actions
- [ ] Sign and notarize the app with Developer ID
- [ ] Publish the first release

## Development workflow

- The `main` branch must stay stable; work happens on short-lived branches such as
  `feat/...`, `fix/...`, `docs/...`, and `chore/...`.
- Changes reach `main` through pull requests, with passing tests.
- Commits follow the [Conventional Commits](https://www.conventionalcommits.org/)
  specification.
- Usage data, trained models, and secrets never enter the repository.
- `README.md` is the primary documentation, and `README.pt-BR.md` must be kept in sync
  with it.

## License

This project does not have a license yet. Until one is chosen, all rights are reserved
by the author.
