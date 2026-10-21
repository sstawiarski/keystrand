import RedisUI
import SwiftUI

struct TLSSectionView: View {
    @Bindable var tls: TLSFormModel
    let certificates: CertificateCatalog

    @State private var certificateToDelete: SavedCertificate?

    struct SavedCertificate: Identifiable {
        let id: String
        let name: String
        let isCA: Bool
    }

    var body: some View {
        Section("TLS") {
            Toggle("Use TLS", isOn: $tls.enabled.animation())
                .modifier(DeleteCertificateConfirmation(certificate: $certificateToDelete, tls: tls, certificates: certificates))
            if tls.enabled {
                Toggle("Use SNI", isOn: $tls.useSNI.animation())
                if tls.useSNI {
                    TextField("Server Name", text: $tls.servername, prompt: Text("Required"))
                }

                Toggle("Verify TLS certificate", isOn: $tls.verifyServerCert)
                caPicker
                if case .existing(let id) = tls.caChoice {
                    deleteButton(SavedCertificate(id: id, name: certificates.caName(id) ?? "Certificate", isCA: true))
                }

                if tls.caChoice == .addNew {
                    TextField("Name", text: $tls.newCAName, prompt: Text("Required"))
                    PEMEditor(title: "Certificate", prompt: "-----BEGIN CERTIFICATE-----", text: $tls.newCACertificate)
                }

                Toggle("Requires TLS client authentication", isOn: $tls.requiresClientAuth.animation())
                if tls.requiresClientAuth {
                    clientPicker
                    if case .existing(let id) = tls.clientChoice {
                        deleteButton(SavedCertificate(id: id, name: certificates.clientName(id) ?? "Certificate",
                                                      isCA: false))
                    }

                    if tls.clientChoice == .addNew {
                        TextField("Name", text: $tls.newClientName, prompt: Text("Required"))
                        PEMEditor(title: "Certificate", prompt: "-----BEGIN CERTIFICATE-----",
                                  text: $tls.newClientCertificate)
                        PEMEditor(title: "Private Key", prompt: "-----BEGIN PRIVATE KEY-----", text: $tls.newClientKey,
                                  masked: true)
                    }
                }
            }
        }
    }

    private var caPicker: some View {
        Picker("CA Certificate", selection: $tls.caChoice) {
            Text("None").tag(CACertificateChoice.none)
            ForEach(certificates.caCertificates) { cert in
                Text(cert.name).tag(CACertificateChoice.existing(cert.id))
            }
            Divider()
            Text("Add New…").tag(CACertificateChoice.addNew)
        }
        .pickerStyle(.menu)
    }

    private var clientPicker: some View {
        Picker("Client Certificate", selection: $tls.clientChoice) {
            ForEach(certificates.clientCertificates) { cert in
                Text(cert.name).tag(ClientCertificateChoice.existing(cert.id))
            }
            if !certificates.clientCertificates.isEmpty { Divider() }
            Text("Add New…").tag(ClientCertificateChoice.addNew)
        }
        .pickerStyle(.menu)
    }

    private func deleteButton(_ certificate: SavedCertificate) -> some View {
        HStack {
            Spacer()
            Button("Delete Certificate…") { certificateToDelete = certificate }
                .help("Delete “\(certificate.name)” from Keystrand")
        }
    }
}

/// Confirms deleting a saved certificate, then detaches it from the form.
private struct DeleteCertificateConfirmation: ViewModifier {
    @Binding var certificate: TLSSectionView.SavedCertificate?
    let tls: TLSFormModel
    let certificates: CertificateCatalog

    func body(content: Content) -> some View {
        content.destructiveConfirmation(
            item: $certificate,
            title: { "Delete “\(DatabaseListLogic.confirmationName($0.name))”?" },
            message: { _ in "The certificate will be removed from Keystrand and from every database that uses it." },
            confirmTitle: "Delete") { certificate in
            Task {
                if await certificates.delete(id: certificate.id, isCA: certificate.isCA) {
                    tls.certificateDeleted(id: certificate.id, isCA: certificate.isCA)
                }
            }
        }
    }
}
