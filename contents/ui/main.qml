/*
    SPDX-FileCopyrightText: 2013 Sebastian Kügler <sebas@kde.org>
    SPDX-FileCopyrightText: 2015 Martin Klapetek <mklapetek@kde.org>
    SPDX-FileCopyrightText: 2021 Carl Schwan <carlschwan@kde.org>
    SPDX-FileCopyrightText: 2023 ivan tkachenko <me@ratijas.tk>

    SPDX-License-Identifier: GPL-2.0-or-later
*/

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.ksvg as KSvg
import org.kde.plasma.workspace.calendar as PlasmaCalendar
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.private.digitalclock
import org.kde.config as KConfig
import org.kde.kcmutils as KCMUtils
import org.kde.kirigami as Kirigami

// Top-level layout containing:
// - Leading column with world clock and agenda view
// - Trailing column with current date header and calendar
//
// Trailing column fills exactly half of the popup width, then there's 1
// logical pixel wide separator, and the rest is left for the Leading.
// Representation's header is intentionally zero-sized, because Calendar view
// brings its own header, and there's currently no other way to stack them.
PlasmoidItem {
    id: calendar

    Plasmoid.backgroundHints: "NoBackground"

    // TODO - delete this?: readonly property var appletInterface: root

    Kirigami.Theme.colorSet: Kirigami.Theme.Window
    Kirigami.Theme.inherit: false

    //Layout.minimumWidth: (calendar.showAgenda || calendar.showClocks) ? Kirigami.Units.gridUnit * 45 : Kirigami.Units.gridUnit * 22
    //Layout.maximumWidth: Kirigami.Units.gridUnit * 80

    //Layout.minimumHeight: Kirigami.Units.gridUnit * 25
    //Layout.maximumHeight: Kirigami.Units.gridUnit * 40

    property bool collapseMarginsHint: true

    readonly property int paddings: Kirigami.Units.largeSpacing
    readonly property bool showAgenda: eventPluginsManager.enabledPlugins.length > 0
    readonly property bool showClocks: Plasmoid.configuration.selectedTimeZones.length > 1

    readonly property alias monthView: monthView

    readonly property string dateFormatString: setDateFormatString()

    property list<string> allTimeZones

    readonly property date currentDateTimeInSelectedTimeZone: {
        const data = dataSource.data[Plasmoid.configuration.lastSelectedTimezone];
        // The order of signal propagation is unspecified, so we might get
        // here before the dataSource has updated. Alternatively, a buggy
        // configuration view might set lastSelectedTimezone to a new time
        // zone before applying the new list, or it may just be set to
        // something invalid in the config file.
        if (data === undefined) {
            return new Date();
        }
        // get the time for the given time zone from the dataengine
        const now = data["DateTime"];
        // get current UTC time
        const nowUtcMilliseconds = now.getTime() + (now.getTimezoneOffset() * 60000);
        const selectedTimeZoneOffsetMilliseconds = data["Offset"] * 1000;
        // add the selected time zone's offset to it
        return new Date(nowUtcMilliseconds + selectedTimeZoneOffsetMilliseconds);
    }

    function initTimeZones() {
        const timeZones = [];
        if (Plasmoid.configuration.selectedTimeZones.indexOf("Local") === -1) {
            timeZones.push("Local");
        }
        calendar.allTimeZones = timeZones.concat(Plasmoid.configuration.selectedTimeZones);
    }

    function timeForZone(timeZone: string, showSeconds: bool): string {
        if (!compactRepresentationItem) {
            return "";
        }

        const data = dataSource.data[timeZone];
        if (data === undefined) {
            return "";
        }

        // get the time for the given time zone from the dataengine
        const now = data["DateTime"];
        // get current UTC time
        const msUTC = now.getTime() + (now.getTimezoneOffset() * 60000);
        // add the dataengine TZ offset to it
        const dateTime = new Date(msUTC + (data["Offset"] * 1000));

        let formattedTime;
        if (showSeconds) {
            formattedTime = Qt.formatTime(dateTime, compactRepresentationItem.timeFormatWithSeconds);
        } else {
            formattedTime = Qt.formatTime(dateTime, compactRepresentationItem.timeFormat);
        }

        if (dateTime.getDay() !== dataSource.data["Local"]["DateTime"].getDay()) {
            formattedTime += " (" + compactRepresentationItem.dateFormatter(dateTime) + ")";
        }

        return formattedTime;
    }

    function displayStringForTimeZone(timeZone: string): string {
        const data = dataSource.data[timeZone];
        if (data === undefined) {
            return timeZone;
        }

        // add the time zone string to the clock
        if (Plasmoid.configuration.displayTimezoneAsCode) {
            return data["Timezone Abbreviation"];
        } else {
            return TimeZonesI18n.i18nCity(data["Timezone"]);
        }
    }

    function selectedTimeZonesDeduplicatingExplicitLocalTimeZone():/* [string] */var {
        const displayStringForLocalTimeZone = displayStringForTimeZone("Local");
        /*
         * Don't add this item if it's the same as the local time zone, which
         * would indicate that the user has deliberately added a dedicated entry
         * for the city of their normal time zone. This is not an error condition
         * because the user may have done this on purpose so that their normal
         * local time zone shows up automatically while they're traveling and
         * they've switched the current local time zone to something else. But
         * with this use case, when they're back in their normal local time zone,
         * the clocks list would show two entries for the same city. To avoid
         * this, let's suppress the duplicate.
         */
        const isLiterallyLocalOrResolvesToSomethingOtherThanLocal = timeZone =>
            timeZone === "Local" || displayStringForTimeZone(timeZone) !== displayStringForLocalTimeZone;

        return Plasmoid.configuration.selectedTimeZones
            .filter(isLiterallyLocalOrResolvesToSomethingOtherThanLocal);
    }

    function timeZoneResolvesToLastSelectedTimeZone(timeZone: string): bool {
        return timeZone === Plasmoid.configuration.lastSelectedTimezone
            || displayStringForTimeZone(timeZone) === displayStringForTimeZone(Plasmoid.configuration.lastSelectedTimezone);
    }

    function setDateFormatString() {
        // remove "dddd" from the locale format string
        // /all/ locales in LongFormat have "dddd" either
        // at the beginning or at the end. so we just
        // remove it + the delimiter and space
        let format = Qt.locale().dateFormat(Locale.LongFormat);
        format = format.replace(/(^dddd.?\s)|(,?\sdddd$)/, "");
        return format;
    }

    P5Support.DataSource {
        id: dataSource
        engine: "time"
        connectedSources: allTimeZones
        interval: intervalAlignment === P5Support.Types.NoAlignment ? 1000 : 60000
        intervalAlignment: P5Support.Types.AlignToMinute
    }

    Keys.onDownPressed: event => {
        monthView.Keys.downPressed(event);
    }

    // TODO: I would like to run monthView.resetToToday() after a period of inactivity...
    /*Connections {
        target: root

        function onExpandedChanged() {
            // clear all the selections when the plasmoid is showing/hiding
            monthView.resetToToday();
        }
    }*/

    PlasmaCalendar.EventPluginsManager {
        id: eventPluginsManager
        enabledPlugins: Plasmoid.configuration.enabledCalendarPlugins
    }


    // LOOK AT THE FILE: scrap.tmp for the original content!

    // Vertical alignment
    // First - Month Title - 80px
    // Second - Navigation for Calendar - 300px
    // Third - Divider line
    // Fourth - Agenda - FILL
    ColumnLayout {

        anchors {
            top: parent.top
            left: parent.left
            bottom: parent.bottom
            right: parent.right
        }

        Layout.fillWidth: true
        Layout.fillHeight: true

        // Second - Calendar
        PlasmaCalendar.MonthView {
            id: monthView

            anchors {
                top: parent.top
                left: parent.left
                right: parent.right
                leftMargin: Kirigami.Units.smallSpacing
                rightMargin: Kirigami.Units.smallSpacing
                bottomMargin: Kirigami.Units.smallSpacing
            }

            height: 380
            Layout.fillWidth: true

            borderOpacity: 0.25

            eventPluginsManager: eventPluginsManager
            today: currentDateTimeInSelectedTimeZone
            firstDayOfWeek: Plasmoid.configuration.firstDayOfWeek > -1
                ? Plasmoid.configuration.firstDayOfWeek
                : Qt.locale().firstDayOfWeek
            showWeekNumbers: Plasmoid.configuration.showWeekNumbers

            showDigitalClockHeader: false
            digitalClock: Plasmoid
            eventButton: addEventButton

            KeyNavigation.left: KeyNavigation.tab
            KeyNavigation.tab: addEventButton.visible ? addEventButton : addEventButton.KeyNavigation.down
            Keys.onUpPressed: event => {
                viewHeader.tabBar.currentItem.forceActiveFocus(Qt.BacktabFocusReason);
            }
        }

        // Third - Divider line
        // Horizontal separator line between events and time zones
        KSvg.SvgItem {
            //visible: worldClocks.visible && agenda.visible

            Layout.fillWidth: true
            Layout.preferredHeight: naturalSize.height

            imagePath: "widgets/line"
            elementId: "horizontal-line"
        }

        // Fourth - Agenda
        // Agenda view itself
        Item {
            id: agenda
            //visible: calendar.showAgenda

            Layout.fillWidth: true
            Layout.fillHeight: true
            //Layout.minimumHeight: Kirigami.Units.gridUnit * 4

            anchors {
                bottom: parent.bottom
                right: parent.right
            }
            height: parent.height - 300

            function formatDateWithoutYear(date: date): string {
                // Unfortunatelly Qt overrides ECMA's Date.toLocaleDateString(),
                // which is able to return locale-specific date-and-month-only date
                // formats, with its dumb version that only supports Qt::DateFormat
                // enum subset. So to get a day-and-month-only date format string we
                // must resort to this magic and hope there are no locales that use
                // other separators...
                const format = Qt.locale().dateFormat(Locale.ShortFormat).replace(/[./ ]*Y{2,4}[./ ]*/i, '');
                return Qt.formatDate(date, format);
            }

            function dateEquals(date1: date, date2: date): bool {
                // Compare two dates without taking time into account
                return date1.getFullYear() === date2.getFullYear()
                    && date1.getMonth() === date2.getMonth()
                    && date1.getDate() === date2.getDate();
            }

            function updateEventsForCurrentDate() {
                eventsList.model = monthView.daysModel.eventsForDate(monthView.currentDate);
            }

            Connections {
                target: monthView

                function onCurrentDateChanged() {
                    agenda.updateEventsForCurrentDate();
                }
            }

            Connections {
                target: monthView.daysModel

                function onAgendaUpdated(updatedDate: date) {
                    if (agenda.dateEquals(updatedDate, monthView.currentDate)) {
                        agenda.updateEventsForCurrentDate();
                    }
                }
            }

            TextMetrics {
                id: dateLabelMetrics

                // Date/time are arbitrary values with all parts being two-digit
                readonly property string timeString: Qt.formatTime(new Date(2000, 12, 12, 12, 12, 12, 12))
                readonly property string dateString: agenda.formatDateWithoutYear(new Date(2000, 12, 12, 12, 12, 12))

                font: Kirigami.Theme.defaultFont
                text: timeString.length > dateString.length ? timeString : dateString
            }

            PlasmaComponents.ScrollView {
                id: eventsView
                anchors.fill: parent

                ListView {
                    id: eventsList

                    focus: false
                    activeFocusOnTab: true
                    highlight: null
                    currentIndex: -1

                    KeyNavigation.down: switchTimeZoneButton.visible ? switchTimeZoneButton : clocksList
                    Keys.onRightPressed: event => switchTimeZoneButton.Keys.rightPressed(event)

                    onCurrentIndexChanged: if (!activeFocus) {
                        currentIndex = -1;
                    }

                    onActiveFocusChanged: if (activeFocus) {
                        currentIndex = 0;
                    } else {
                        currentIndex = -1;
                    }

                    delegate: PlasmaComponents.ItemDelegate {
                        id: eventItem

                        // Crashes if the type is declared as eventData (which is Q_GADGET)
                        required property /*PlasmaCalendar.eventData*/var modelData

                        width: ListView.view.width

                        leftPadding: calendar.paddings

                        text: eventTitle.text
                        hoverEnabled: true
                        highlighted: ListView.isCurrentItem
                        Accessible.description: modelData.description
                        readonly property bool hasTime: {
                            // Explicitly all-day event
                            if (modelData.isAllDay) {
                                return false;
                            }
                            // Multi-day event which does not start or end today (so
                            // is all-day from today's point of view)
                            if (modelData.startDateTime - monthView.currentDate < 0 &&
                                modelData.endDateTime - monthView.currentDate > 86400000) { // 24hrs in ms
                                return false;
                            }

                            // Non-explicit all-day event
                            const startIsMidnight = modelData.startDateTime.getHours() === 0
                                && modelData.startDateTime.getMinutes() === 0;

                            const endIsMidnight = modelData.endDateTime.getHours() === 0
                                && modelData.endDateTime.getMinutes() === 0;

                            const sameDay = modelData.startDateTime.getDate() === modelData.endDateTime.getDate()
                                && modelData.startDateTime.getDay() === modelData.endDateTime.getDay();

                            return !(startIsMidnight && endIsMidnight && sameDay);
                        }

                        PlasmaComponents.ToolTip {
                            text: eventItem.modelData.description
                            visible: text !== "" && eventItem.hovered
                        }

                        contentItem: GridLayout {
                            id: eventGrid
                            columns: 3
                            rows: 2
                            rowSpacing: 0
                            columnSpacing: Kirigami.Units.largeSpacing

                            Rectangle {
                                id: eventColor

                                Layout.row: 0
                                Layout.column: 0
                                Layout.rowSpan: 2
                                Layout.fillHeight: true

                                color: eventItem.modelData.eventColor
                                width: 5
                                visible: eventItem.modelData.eventColor !== ""
                            }

                            PlasmaComponents.Label {
                                id: startTimeLabel

                                readonly property bool startsToday: eventItem.modelData.startDateTime - monthView.currentDate >= 0
                                readonly property bool startedYesterdayLessThan12HoursAgo: eventItem.modelData.startDateTime - monthView.currentDate >= -43200000 //12hrs in ms

                                Layout.row: 0
                                Layout.column: 1
                                Layout.minimumWidth: dateLabelMetrics.width

                                text: startsToday || startedYesterdayLessThan12HoursAgo
                                    ? Qt.formatTime(eventItem.modelData.startDateTime)
                                    : agenda.formatDateWithoutYear(eventItem.modelData.startDateTime)
                                textFormat: Text.PlainText
                                horizontalAlignment: Qt.AlignRight
                                visible: eventItem.hasTime
                            }

                            PlasmaComponents.Label {
                                id: endTimeLabel

                                readonly property bool endsToday: eventItem.modelData.endDateTime - monthView.currentDate <= 86400000 // 24hrs in ms
                                readonly property bool endsTomorrowInLessThan12Hours: eventItem.modelData.endDateTime - monthView.currentDate <= 86400000 + 43200000 // 36hrs in ms

                                Layout.row: 1
                                Layout.column: 1
                                Layout.minimumWidth: dateLabelMetrics.width

                                text: endsToday || endsTomorrowInLessThan12Hours
                                    ? Qt.formatTime(eventItem.modelData.endDateTime)
                                    : agenda.formatDateWithoutYear(eventItem.modelData.endDateTime)
                                textFormat: Text.PlainText
                                horizontalAlignment: Qt.AlignRight
                                opacity: 0.7

                                visible: eventItem.hasTime
                            }

                            PlasmaComponents.Label {
                                id: eventTitle

                                Layout.row: 0
                                Layout.column: 2
                                Layout.fillWidth: true

                                elide: Text.ElideRight
                                text: eventItem.modelData.title
                                textFormat: Text.PlainText
                                verticalAlignment: Text.AlignVCenter
                                maximumLineCount: 2
                                wrapMode: Text.Wrap
                            }
                        }
                    }
                }
            }

            PlasmaExtras.PlaceholderMessage {
                anchors.centerIn: eventsView
                width: eventsView.width - (Kirigami.Units.gridUnit * 8)

                visible: eventsList.count === 0

                iconName: "checkmark"
                text: monthView.isToday(monthView.currentDate)
                    ? i18n("No events for today")
                    : i18n("No events for this day");

            }
        }
    }
}
