import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A weather-forecast card: the condition and temperature now, and — when the
// card shows a forecast — the next days or hours. Weather entities stopped
// carrying their forecast as an attribute, so it comes from a
// weather/subscribe_forecast subscription that lives as long as this card.
Column {
  id: weather

  property var host: null
  property string entity: ""
  property string name: ""
  property bool showForecast: true
  property bool showCurrent: true
  property string forecastType: "daily"

  readonly property var service: host ? host.service : null
  readonly property var st: service ? service.stateOf(entity, service.stateRevision) : null
  readonly property var attrs: st && st.attributes ? st.attributes : ({})
  readonly property string subscriptionKey: "forecast:" + entity + ":" + forecastType
  readonly property var forecastEvent: service && showForecast ? service.subscriptionEvent(subscriptionKey, service.subscriptionRevision) : null
  readonly property var rows: Model.forecastRows(forecastEvent ? forecastEvent.forecast : [], forecastType, 5)

  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  spacing: Style.spacing.lg

  property string subscribedKey: ""

  function resubscribe() {
    if (!service) return
    if (subscribedKey !== "") service.unsubscribe(subscribedKey)
    subscribedKey = ""
    if (!showForecast || entity === "") return
    subscribedKey = subscriptionKey
    service.subscribe(subscribedKey, { type: "weather/subscribe_forecast", entity_id: entity, forecast_type: forecastType })
  }

  onServiceChanged: resubscribe()
  onSubscriptionKeyChanged: resubscribe()
  Component.onDestruction: if (service && subscribedKey !== "") service.unsubscribe(subscribedKey)

  Item {
    visible: weather.showCurrent
    width: parent.width
    height: Math.max(conditionIcon.implicitHeight, nowColumn.implicitHeight)

    Text {
      id: conditionIcon
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: Model.entityGlyph(weather.entity, weather.st, "", null)
      font.family: weather.fontFamily
      font.pixelSize: Style.font.displayLarge * 1.4
      color: weather.foreground
    }

    Column {
      anchors.left: conditionIcon.right
      anchors.leftMargin: Style.spacing.xl
      anchors.verticalCenter: parent.verticalCenter
      Text {
        text: Model.stateText(weather.st, null)
        font.family: weather.fontFamily
        font.pixelSize: Style.font.title
        color: weather.foreground
      }
      Text {
        text: Model.entityName(weather.entity, weather.st, weather.name)
        font.family: weather.fontFamily
        font.pixelSize: Style.font.caption
        color: weather.dim
      }
    }

    Column {
      id: nowColumn
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      Text {
        anchors.right: parent.right
        text: weather.attrs.temperature !== undefined ? weather.attrs.temperature + " " + (weather.attrs.temperature_unit || "°") : ""
        font.family: weather.fontFamily
        font.pixelSize: Style.font.display
        color: weather.foreground
      }
      Text {
        anchors.right: parent.right
        text: [
          weather.attrs.humidity !== undefined ? Model.glyph("mdi:water-percent") + " " + weather.attrs.humidity + "%" : "",
          weather.attrs.wind_speed !== undefined ? Model.glyph("mdi:weather-windy") + " " + weather.attrs.wind_speed + " " + (weather.attrs.wind_speed_unit || "") : ""
        ].filter(function(part) { return part !== "" }).join("   ")
        font.family: weather.fontFamily
        font.pixelSize: Style.font.caption
        color: weather.dim
      }
    }
  }

  Row {
    visible: weather.showForecast && weather.rows.length > 0
    width: parent.width

    Repeater {
      model: weather.rows

      Column {
        required property var modelData
        width: weather.width / Math.max(1, weather.rows.length)
        spacing: Style.spacing.xxs

        Text {
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          text: modelData.label
          font.family: weather.fontFamily; font.pixelSize: Style.font.caption; color: weather.dim
        }
        Text {
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          text: Model.glyph(modelData.icon)
          font.family: weather.fontFamily; font.pixelSize: Style.font.iconLarge; color: weather.foreground
        }
        Text {
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          text: modelData.high + (modelData.low !== "" ? " / " + modelData.low : "")
          font.family: weather.fontFamily; font.pixelSize: Style.font.caption; color: weather.foreground
        }
        Text {
          width: parent.width; horizontalAlignment: Text.AlignHCenter
          visible: modelData.rain !== ""
          text: modelData.rain
          font.family: weather.fontFamily; font.pixelSize: Style.font.caption; color: weather.dim
        }
      }
    }
  }
}
