import MapKit
import RedisUI
import SwiftUI

/// GEO* results: MapKit map or heatmap of members (requires coordinates), or the details view.
struct GeoResultView: View {
    enum Style {
        case map
        case heatmap
        case details

        var title: String {
            switch self {
            case .map: return "Geospatial Map"
            case .heatmap: return "Geospatial Heatmap"
            case .details: return "Geospatial Details"
            }
        }
    }

    let geo: GeoModel
    let style: Style
    let isFullscreen: Bool

    static let missingCoordinatesMessage = "Add WITHCOORD to the command to plot results on a map."
    static let noRowsMessage = "No geospatial rows returned."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(style.title).font(.headline)
                if geo.metric == nil {
                    Text("\(geo.rows.count) result(s)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            switch style {
            case .map, .heatmap:
                if geo.rows.isEmpty {
                    Text(Self.noRowsMessage).foregroundStyle(.secondary)
                } else if geo.hasCoordinates, !geo.locatedRows.isEmpty {
                    GeoMapView(geo: geo, isHeatmap: style == .heatmap)
                        .frame(height: isFullscreen ? nil : 320)
                        .frame(maxHeight: isFullscreen ? .infinity : 320)
                } else {
                    InlineMessage(Self.missingCoordinatesMessage, kind: .warning)
                }
            case .details:
                details
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        if !geo.summary.isEmpty {
            HStack(alignment: .top, spacing: 20) {
                ForEach(geo.summary, id: \.label) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label).font(.caption).foregroundStyle(.secondary)
                        Text(item.value).font(.body.monospaced()).lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
        }

        if let metric = geo.metric {
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.label).font(.caption).foregroundStyle(.secondary)
                Text(metric.value).font(.title3.weight(.semibold)).textSelection(.enabled)
            }
        } else {
            DataGridView(columns: GeoModel.columns, rows: geo.tableRows,
                         maxHeight: isFullscreen ? nil : VisualizationMetrics.maxHeight, sortable: true,
                         emptyText: Self.noRowsMessage)
        }
    }
}

struct GeoMapView: View {
    let geo: GeoModel
    var isHeatmap = false
    @State private var position: MapCameraPosition = .automatic

    /// Heat spot rings from outer to inner (radius factor, color, opacity); overlapping spots add up.
    static let heatRings: [(scale: Double, color: Color, opacity: Double)] = [
        (1.0, .yellow, 0.12),
        (0.6, .orange, 0.16),
        (0.3, .red, 0.24),
    ]

    var body: some View {
        let located = geo.locatedRows
        let radius = geo.heatRadiusMeters
        Map(position: $position) {
            if isHeatmap {
                ForEach(located) { row in
                    if let coordinate = row.coordinate {
                        ForEach(Self.heatRings.indices, id: \.self) { index in
                            let ring = Self.heatRings[index]
                            MapCircle(center: coordinate, radius: radius * ring.scale)
                                .foregroundStyle(ring.color.opacity(ring.opacity))
                        }
                    }
                }
            } else {
                ForEach(located) { row in
                    if let coordinate = row.coordinate {
                        Marker(row.member, coordinate: coordinate)
                            .tint(Color.accentColor)
                    }
                }
            }

            if let center = geo.center {
                Marker("Query Center", systemImage: "scope", coordinate: center)
                    .tint(.gray)
            }
        }
        .mapControls {
            MapZoomStepper()
            MapCompass()
            MapScaleView()
        }
    }
}

extension GeoRow {
    var coordinate: CLLocationCoordinate2D? {
        guard let longitude, let latitude, (-180...180).contains(longitude), (-90...90).contains(latitude) else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension GeoModel {
    static let columns = ["Member", "Longitude", "Latitude", "Distance", "Hash"]

    var locatedRows: [GeoRow] { rows.filter { $0.coordinate != nil } }

    var center: CLLocationCoordinate2D? {
        guard let centerLongitude, let centerLatitude else { return nil }
        return CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
    }

    /// Heat spot radius: about 1/25 of the spread of the points, at least 50 m.
    var heatRadiusMeters: Double {
        let coordinates = locatedRows.compactMap(\.coordinate)
        guard let first = coordinates.first else { return 50 }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }

        let spread = CLLocation(latitude: minLat, longitude: minLon)
            .distance(from: CLLocation(latitude: maxLat, longitude: maxLon))
        return max(50, spread / 25)
    }

    var tableRows: [[String: String]] {
        rows.map { row in
            [
                "Member": row.member,
                "Longitude": row.longitude.map { String($0) } ?? "-",
                "Latitude": row.latitude.map { String($0) } ?? "-",
                "Distance": row.distance ?? "-",
                "Hash": row.hash ?? "-",
            ]
        }
    }
}
