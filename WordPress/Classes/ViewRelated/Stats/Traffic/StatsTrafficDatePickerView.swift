import SwiftUI
import DesignSystem

struct StatsTrafficDatePickerView: View {
    @ObservedObject var viewModel: StatsTrafficDatePickerViewModel

    private let maxDynamicTypeSize: DynamicTypeSize = .xxxLarge

    var body: some View {
        HStack {
            Menu {
                ForEach([StatsPeriodUnit.day, .week, .month, .year], id: \.self) { period in
                    Button(period.label, action: {
                        viewModel.period = period
                    })
                }
            } label: {
                HStack {
                    Text(viewModel.period.label)
                        .style(TextStyle.bodySmall(.emphasized))
                        .foregroundColor(Color.DS.Foreground.primary)
                        .dynamicTypeSize(...maxDynamicTypeSize)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundColor(Color.DS.Foreground.secondary)
                        .dynamicTypeSize(...maxDynamicTypeSize)
                }
                .padding(.vertical, .DS.Padding.single)
                .padding(.horizontal, .DS.Padding.double)
                .background(Color.DS.Background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: .DS.Radius.max))
                .overlay(
                    RoundedRectangle(cornerRadius: .DS.Radius.max)
                        .strokeBorder(.clear, lineWidth: 0)
                )
                .padding(.vertical, .DS.Padding.single)
                .padding(.horizontal, .DS.Padding.double)
            }
            .menuStyle(.borderlessButton)

            Spacer()

            Text(viewModel.formattedCurrentPeriod())
                .style(TextStyle.bodySmall(.emphasized))
                .foregroundColor(Color.DS.Foreground.primary)
                .lineLimit(1)
                .dynamicTypeSize(...maxDynamicTypeSize)

            Spacer().frame(width: .DS.Padding.split)

            HStack {
                let isNextDisabled = !viewModel.isNextPeriodAvailable
                let isPreviousDisabled = !viewModel.isPreviousPeriodAvailable
                let enabledColor = Color.DS.Foreground.secondary
                let disabledColor = enabledColor.opacity(0.5)

                Button(action: {
                    viewModel.goToPreviousPeriod()
                }) {
                    Image(systemName: "chevron.left")
                        .imageScale(.small)
                        .foregroundColor(isPreviousDisabled ? disabledColor : enabledColor)
                        .flipsForRightToLeftLayoutDirection(true)
                        .padding(.vertical, .DS.Padding.double)
                        .contentShape(Rectangle())
                        .dynamicTypeSize(...maxDynamicTypeSize)
                }.disabled(isPreviousDisabled)
                .padding(.trailing, .DS.Padding.single)

                Button(action: {
                    viewModel.goToNextPeriod()
                }) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundColor(isNextDisabled ? disabledColor : enabledColor)
                        .flipsForRightToLeftLayoutDirection(true)
                        .padding(.vertical, .DS.Padding.double)
                        .contentShape(Rectangle())
                        .dynamicTypeSize(...maxDynamicTypeSize)
                }.disabled(isNextDisabled)
            }.padding(.trailing, .DS.Padding.medium)

        }.background(Color.DS.Background.primary)
            .overlay(
                Rectangle()
                    .frame(height: .DS.Border.thin)
                    .foregroundColor(Color.DS.Foreground.tertiary),
                alignment: .bottom
            )
            .background(Color.DS.Background.secondary)
    }
}

private extension StatsPeriodUnit {
    var label: String {
        switch self {
        case .day:
            return NSLocalizedString("stats.traffic.days", value: "Days", comment: "The label for the option to show Stats Traffic chart for Days.")
        case .week:
            return NSLocalizedString("stats.traffic.weeks", value: "Weeks", comment: "The label for the option to show Stats Traffic chart for Weeks.")
        case .month:
            return NSLocalizedString("stats.traffic.months", value: "Months", comment: "The label for the option to show Stats Traffic chart for Months.")
        case .year:
            return NSLocalizedString("stats.traffic.years", value: "Years", comment: "The label for the option to show Stats Traffic chart for Years.")
        }
    }
}
