import SwiftUI
import PhotosUI

struct PrescriptionScannerView: View {
    var onScanComplete: (PrescriptionLabelScanner.ScannedPrescriptionData) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var capturedImage: UIImage?
    @State private var scanResult: PrescriptionLabelScanner.ScannedPrescriptionData?
    @State private var isScanning = false
    @State private var showCamera = true
    @State private var errorMessage: String?
    @State private var selectedPhotoItem: PhotosPickerItem?

    /// Controls whether the camera or photo library picker is shown.
    enum ImageSource: String, CaseIterable {
        case camera = "Camera"
        case library = "Photo Library"
    }
    @State private var imageSource: ImageSource = .camera

    var body: some View {
        NavigationStack {
            Group {
                if let scanResult {
                    reviewForm(scanResult)
                } else if isScanning {
                    scanningView
                } else {
                    sourcePickerView
                }
            }
            .navigationTitle("Scan Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Source Picker

    private var sourcePickerView: some View {
        VStack(spacing: 20) {
            Picker("Image Source", selection: $imageSource) {
                ForEach(ImageSource.allCases, id: \.self) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            switch imageSource {
            case .camera:
                cameraSection
            case .library:
                librarySection
            }

            Spacer()
        }
        .padding(.top)
        .sheet(isPresented: $showCamera) {
            CameraPickerRepresentable { image in
                handleCapturedImage(image)
            } onCancel: {
                showCamera = false
            }
            .ignoresSafeArea()
        }
        .onChange(of: imageSource) {
            // Reset state when switching sources
            showCamera = (imageSource == .camera)
            errorMessage = nil
        }
        .onChange(of: selectedPhotoItem) {
            loadFromLibrary()
        }
    }

    private var cameraSection: some View {
        VStack(spacing: 16) {
            if let errorMessage {
                errorBanner(errorMessage)
            }

            Text("Position the prescription label within the camera frame.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                showCamera = true
            } label: {
                Label("Open Camera", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
    }

    private var librarySection: some View {
        VStack(spacing: 16) {
            if let errorMessage {
                errorBanner(errorMessage)
            }

            Text("Choose a photo of a prescription label from your library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            PhotosPicker(
                selection: $selectedPhotoItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Choose Photo", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
    }

    // MARK: - Scanning State

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Scanning label...")
                .font(.headline)
            Text("Reading text from the prescription label")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Review Form

    private func reviewForm(_ data: PrescriptionLabelScanner.ScannedPrescriptionData) -> some View {
        Form {
            Section("Detected Fields") {
                fieldRow("Rx Number", value: data.rxNumber)
                fieldRow("Medication", value: data.medicationName)
                fieldRow("Dose", value: data.dose)
                fieldRow("Quantity", value: data.quantity.map(String.init))
                fieldRow("Refills", value: data.refillsRemaining.map(String.init))
                fieldRow("Pharmacy", value: data.pharmacyName)
                fieldRow("Date Filled", value: data.dateFilled.map { formattedDate($0) })
            }

            if !data.rawText.isEmpty {
                Section("Raw Text") {
                    ForEach(Array(data.rawText.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    onScanComplete(data)
                    dismiss()
                } label: {
                    Text("Use These Values")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button("Retake Photo") {
                    resetForRetake()
                }

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Helpers

    private func fieldRow(_ label: String, value: String?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value ?? "Not detected")
                .foregroundStyle(value != nil ? .primary : .secondary)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.subheadline)
            }
            Button("Try Again") {
                errorMessage = nil
                if imageSource == .camera {
                    showCamera = true
                }
            }
            .font(.subheadline)
        }
        .padding()
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private func resetForRetake() {
        capturedImage = nil
        scanResult = nil
        isScanning = false
        errorMessage = nil
        selectedPhotoItem = nil
        if imageSource == .camera {
            showCamera = true
        }
    }

    // MARK: - Image Handling

    private func handleCapturedImage(_ image: UIImage) {
        showCamera = false
        capturedImage = image
        performScan(on: image)
    }

    private func loadFromLibrary() {
        guard let item = selectedPhotoItem else { return }

        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    errorMessage = "Could not load the selected image."
                    return
                }
                capturedImage = image
                performScan(on: image)
            } catch {
                errorMessage = "Failed to load image: \(error.localizedDescription)"
            }
        }
    }

    private func performScan(on image: UIImage) {
        isScanning = true
        errorMessage = nil

        Task {
            do {
                let result = try await PrescriptionLabelScanner.scan(image: image)
                scanResult = result
            } catch {
                errorMessage = error.localizedDescription
            }
            isScanning = false
        }
    }
}

// MARK: - Camera Picker (UIKit Bridge)

/// UIViewControllerRepresentable that wraps UIImagePickerController for camera capture.
private struct CameraPickerRepresentable: UIViewControllerRepresentable {
    var onImageCaptured: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImageCaptured: onImageCaptured, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImageCaptured: (UIImage) -> Void
        let onCancel: () -> Void

        init(onImageCaptured: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImageCaptured = onImageCaptured
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImageCaptured(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
            picker.dismiss(animated: true)
        }
    }
}
