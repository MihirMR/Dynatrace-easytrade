import type { RouteObject } from "react-router"
import ProtectedLayout from "../layouts/ProtectedLayout"
import { LoaderIds } from "../utils/routeIds"
import { lazyPage } from "./helpers"
import { creditCardRoutes } from "./credit-card.routes"
import { instrumentsRoutes } from "./instruments.routes"
import { userAndBalanceLoader } from "../hooks/useUser"
import { portfolioInsightsLoader } from "../hooks/usePortfolioInsights"

export const protectedRoutes: RouteObject = {
    element: <ProtectedLayout />,
    id: LoaderIds.user,
    loader: userAndBalanceLoader,
    children: [
        {
            path: "withdraw",
            lazy: lazyPage(() => import("../pages/protected/Withdraw")),
        },
        {
            path: "deposit",
            lazy: lazyPage(() => import("../pages/protected/Deposit")),
        },
        {
            path: "insights",
            loader: portfolioInsightsLoader,
            lazy: lazyPage(() =>
                import("../pages/protected/PortfolioInsights").then((m) => ({
                    default: m.PortfolioInsights,
                }))
            ),
        },
        creditCardRoutes,
        instrumentsRoutes,
    ],
}
