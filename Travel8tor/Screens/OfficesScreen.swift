import SwiftData
import SwiftUI

struct OfficesScreen: View {
    @Query(sort: \Office.name) private var offices: [Office]

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.cardGap) {
                if offices.isEmpty {
                    Card(padding: EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16)) {
                        Text("No offices yet.")
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.secondary)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    RowStack(items: offices, inset: 40) { office in
                        NavigationLink {
                            OfficeEditorScreen(office: office)
                        } label: {
                            officeRow(office)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Card {
                    NavigationLink {
                        OfficeEditorScreen()
                    } label: {
                        Text("Add office")
                            .font(.system(size: 16))
                            .foregroundStyle(Palette.tint)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Text(
                    "Each office has its own postcode and perimeter. The arrival alert "
                    + "fires once a day per office. All offices count toward the same "
                    + "monthly target."
                )
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 4)
            .padding(.bottom, 30)
        }
        .background(Palette.ground)
        .navigationTitle("Offices")
    }

    private func officeRow(_ office: Office) -> some View {
        HStack(spacing: 13) {
            OfficeDot(colourHex: office.colourHex, size: 11)
            VStack(alignment: .leading, spacing: 3) {
                Text(office.name)
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.text)
                Text(fullAddress(office))
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
                Text(alertText(office))
                    .font(.system(size: 13))
                    .foregroundStyle(office.alertEnabled ? Palette.met : Palette.secondary)
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.tertiary)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(minHeight: Metrics.minimumRow)
        .contentShape(Rectangle())
    }

    private func alertText(_ office: Office) -> String {
        guard office.alertEnabled else { return "Alert off" }
        // An office with no coordinates cannot be monitored, whatever the
        // toggle says. Saying "Alert on" there would be a promise the app
        // cannot keep.
        guard office.isLocated else { return "Alert on · no location yet" }
        return "Alert on · \(Int(office.radiusMetres))m"
    }
}

/// `25 Ropemaker St, London EC2Y 9LY`.
///
/// The postcode is a separate field because the geocoder wants it on its own,
/// but people type it into the address line as well. Appending it regardless
/// gives `… 1040 Brussels 1040`, so a postcode already in the address is left
/// where it is.
func fullAddress(_ office: Office) -> String {
    let postcode = office.postcode.trimmingCharacters(in: .whitespaces)
    guard !postcode.isEmpty,
          !office.address.localizedCaseInsensitiveContains(postcode) else {
        return office.address
    }
    return office.address.isEmpty ? postcode : "\(office.address) \(postcode)"
}

#Preview {
    NavigationStack { OfficesScreen() }
        .modelContainer(try! Store.makeInMemoryContainer(seeded: true))
}
