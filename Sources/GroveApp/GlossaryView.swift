import SwiftUI

struct GlossaryView: View {
    @ObservedObject var store: GroveStore
    @State private var newTerm = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("회의 사전")
                        .font(.system(.title, design: .serif).weight(.semibold))
                    Text("인식 힌트와 자동 교정 규칙은 분리합니다.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("승인 용어 \(store.glossaryTerms.filter(\.isEnabled).count)개")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            Divider()

            HStack(spacing: 10) {
                TextField("새 고유명사 또는 전문 용어", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTerm)
                Button("추가", action: addTerm)
                    .buttonStyle(.borderedProminent)
                    .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)

            List {
                Section("AnalysisContext에 전달") {
                    ForEach($store.glossaryTerms) { $term in
                        Toggle(isOn: $term.isEnabled) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(term.canonical).fontWeight(.medium)
                                if !term.observedForms.isEmpty {
                                    Text(term.observedForms.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section("자동 교정") {
                    LabeledContent("활성 규칙", value: "0")
                    Text("동일 오인식이 실제 회의에서 반복되고 false-positive 검토를 통과해야 승격됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
        .navigationTitle("사전")
    }

    private func addTerm() {
        store.addGlossaryTerm(newTerm)
        newTerm = ""
    }
}
