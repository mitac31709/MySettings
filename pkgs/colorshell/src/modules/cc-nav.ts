import Windows from "../window";
import type Pages from "../window/control-center/widgets/pages";

let activePages: Pages | null = null;
let pendingPageId: string | null = null;

export function registerControlCenterPages(pages: Pages): () => void {
    activePages = pages;
    if (pendingPageId) {
        const target = pendingPageId;
        pendingPageId = null;
        pages.open(target);
    }
    return () => {
        if (activePages === pages) {
            activePages = null;
        }
    };
}

export function openControlCenterPage(pageId: string): void {
    const wins = Windows.getDefault();
    if (wins.isOpen("control-center") && activePages) {
        if (activePages.isOpen && activePages.currentPageId === pageId) {
            wins.close("control-center");
            return;
        }
        activePages.open(pageId);
        return;
    }
    pendingPageId = pageId;
    wins.open("control-center");
}
