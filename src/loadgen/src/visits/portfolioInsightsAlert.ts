import { IPageActions } from "@demoability/loadgen-core/lib/pageActions"
import { IVisit } from "@demoability/loadgen-core/lib/visits"
import { Logger } from "winston"
import { Page } from "puppeteer"

import { User } from "../user"

import { pageSetup } from "../helpers/common"
import { login } from "../helpers/login"
import { logout } from "../helpers/logout"
import {
    createAndDeleteOwnedAlert,
    gotoPortfolioInsightsPage,
    isPortfolioInsightsEnabled,
} from "../helpers/portfolioInsights"
import { VisitName } from "./types"

export class PortfolioInsightsAlertVisit implements IVisit {
    readonly visitName: VisitName
    readonly url: URL
    readonly user: User
    private readonly fetchFn: typeof fetch
    private readonly random: () => number

    constructor(
        visitName: VisitName,
        url: URL,
        user: User,
        deps: { fetchFn?: typeof fetch; random?: () => number } = {}
    ) {
        this.visitName = visitName
        this.url = url
        this.user = user
        this.fetchFn = deps.fetchFn ?? fetch
        this.random = deps.random ?? Math.random
    }

    getName(): string {
        return this.visitName
    }

    async setup(pageActions: IPageActions, logger: Logger): Promise<void> {
        logger.info(
            `Setting up page for user [${this.user.username}|${this.user.ip4}]`
        )
        await pageActions.setupPage(async (page: Page) => {
            await pageSetup(page, this.user, this.url)
        })
    }

    async run(pageActions: IPageActions, logger: Logger): Promise<void> {
        const enabled = await isPortfolioInsightsEnabled(
            this.url,
            this.fetchFn,
            2000,
            logger
        )
        if (!enabled) {
            logger.info(
                "Flag [portfolio-insights-enabled] is off, skipping portfolio insights visit"
            )
            return
        }

        logger.info(`Going to EasyTrade frontend at [${this.url}]`)
        await pageActions.gotoPage(this.url.toString())

        logger.info(`Logging in as user [${this.user.username}]`)
        await login(pageActions, this.user)

        logger.info("Opening portfolio insights page")
        await gotoPortfolioInsightsPage(pageActions)
        await createAndDeleteOwnedAlert(pageActions, this.url, logger, {
            fetchFn: this.fetchFn,
            random: this.random,
        })

        logger.info(`Logging out user [${this.user.username}]`)
        await logout(pageActions)

        logger.info("Attempting to end dynatrace session")
        await pageActions.endDtSession()
    }
}
