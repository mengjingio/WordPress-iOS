import UIKit

extension BlogDetailsViewController {

    @objc func showSiteMonitoring() {
        showSiteMonitoring(selectedTab: nil)
    }

    @objc func showSiteMonitoring(selectedTab: NSNumber?) {
        guard #available(iOS 16, *) else {
            return
        }
        let selectedTab = selectedTab.flatMap { SiteMonitoringTab(rawValue: $0.intValue) }
        let controller = SiteMonitoringViewController(blog: blog, selectedTab: selectedTab)
        presentationDelegate?.presentBlogDetailsViewController(controller)
    }
}
