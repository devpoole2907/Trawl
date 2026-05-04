import SwiftUI

struct ArrMonitoredToggle: View {
    @Binding var isMonitored: Bool
    
    var body: some View {
        Toggle("Monitored", isOn: $isMonitored)
    }
}
