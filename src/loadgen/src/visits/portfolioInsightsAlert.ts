import { IPageActions } from "@demoability/loadgen-core/lib/pageActions"
import { IVisit } from "@demoability/loadgen-core/lib/visits"
import { Logger } from "winston"
import { Page } from "puppeteer"

import { User } from "../user"

import { pageSetup } from "../helpers/common"
import { logout } from "../helpers/logout"
import {
    isPortfolioInsightsEnabled,
    loginWithoutLoggingPassword,
    openPageAndRunOwnedAlert,
    ownedAlertFailure,
    withVisitLogger,
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
        const enabled = await withVisitLogger(logger, () =>
            isPortfolioInsightsEnabled(this.url, this.fetchFn)
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
        await loginWithoutLoggingPassword(pageActions, this.user)

        // Logged in from here on, so the session is closed whatever happens.
        // The visit then fails with the first error, or when its own alert
        // did not end clean: the worker counts only a normal return as success.
        let failure: { error: unknown } | undefined
        try {
            logger.info("Opening portfolio insights page")
            const outcome = await openPageAndRunOwnedAlert(
                pageActions,
                this.url,
                logger,
                { fetchFn: this.fetchFn, random: this.random }
            )
            const unclean = ownedAlertFailure(outcome)
            if (unclean !== undefined) {
                failure = { error: unclean }
            }
        } catch (error) {
            failure = { error }
        }

        try {
            await this.closeSession(pageActions, logger)
        } catch (error) {
            if (failure === undefined) {
                throw error
            }
            logger.warn("Closing the session after a failed visit failed", {
                error,
            })
        }
        if (failure !== undefined) {
            throw failure.error
        }
    }

    /** Logs out, and ends the Dynatrace session even when logging out fails. */
    private async closeSession(
        pageActions: IPageActions,
        logger: Logger
    ): Promise<void> {
        logger.info(`Logging out user [${this.user.username}]`)
        try {
            await logout(pageActions)
        } finally {
            logger.info("Attempting to end dynatrace session")
            await pageActions.endDtSession()
        }
    }
}
