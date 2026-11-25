import { NavLink } from "react-router"
import {
    HomeIcon,
    InstrumentsIcon,
    DepositIcon,
    WithdrawIcon,
    AddCardIcon,
    InsightsIcon,
} from "./icons"
import { usePortfolioInsightsFlag } from "../hooks/useFeatureFlags"

export default function Navigation() {
    // Observed on every protected route, so the flag keeps revalidating and a
    // disable shuts the feature down wherever the user is.
    const portfolioInsightsEnabled = usePortfolioInsightsFlag()

    return (
        <nav className="sidebar">
            <div className="sidebar-nav">
                <ul>
                    <li>
                        <NavLink
                            id="nav-home"
                            to="/home"
                            className={({ isActive }) =>
                                "nav-link" + (isActive ? " active" : "")
                            }
                        >
                            <HomeIcon />
                            Home
                        </NavLink>
                    </li>
                    <li>
                        <NavLink
                            id="nav-instruments"
                            to="/instruments"
                            className={({ isActive }) =>
                                "nav-link" + (isActive ? " active" : "")
                            }
                        >
                            <InstrumentsIcon />
                            Instruments
                        </NavLink>
                    </li>
                    <li>
                        <NavLink
                            id="nav-deposit"
                            to="/deposit"
                            className={({ isActive }) =>
                                "nav-link" + (isActive ? " active" : "")
                            }
                        >
                            <DepositIcon />
                            Deposit
                        </NavLink>
                    </li>
                    <li>
                        <NavLink
                            id="nav-withdraw"
                            to="/withdraw"
                            className={({ isActive }) =>
                                "nav-link" + (isActive ? " active" : "")
                            }
                        >
                            <WithdrawIcon />
                            Withdraw
                        </NavLink>
                    </li>
                    <li>
                        <NavLink
                            id="nav-credit-card"
                            to="/credit-card"
                            className={({ isActive }) =>
                                "nav-link" + (isActive ? " active" : "")
                            }
                        >
                            <AddCardIcon />
                            Credit Card
                        </NavLink>
                    </li>
                    {portfolioInsightsEnabled && (
                        <li>
                            <NavLink
                                id="nav-portfolio-insights"
                                to="/insights"
                                className={({ isActive }) =>
                                    "nav-link" + (isActive ? " active" : "")
                                }
                            >
                                <InsightsIcon />
                                Portfolio Insights
                            </NavLink>
                        </li>
                    )}
                </ul>
            </div>
        </nav>
    )
}
