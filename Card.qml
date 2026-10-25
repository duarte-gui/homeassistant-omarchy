import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One block of a view, as Model.blocksForView describes it. The frame is the
// same for every kind; what goes inside is picked by `block.kind`. A stack
// holds more blocks, each drawn by another Card — Loader is how a QML file
// gets to contain itself.
Item {
  id: card

  property var block: null
  property var host: null
  property bool framed: true

  readonly property var service: host ? host.service : null
  readonly property string kind: block ? String(block.kind) : ""
  readonly property bool conditionsOk: !block || !block.conditions || block.conditions.length === 0
    || (service && Model.conditionsMet(block.conditions, service.stateStore, service.user, service.stateRevision))
  readonly property bool selfFramed: kind === "stack" || kind === "tiles" || kind === "badges" || kind === "heading"

  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color urgent: host ? host.urgent : Color.urgent
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family
  readonly property int pad: card.framed && !card.selfFramed ? Style.spacing.xl : 0

  readonly property string title: block && block.title ? String(block.title)
    // HA titles a to-do list card with the list's name.
    : kind === "todo" && service ? Model.entityName(block.entity, service.stateOf(block.entity, service.stateRevision), "")
    : ""

  visible: conditionsOk && kind !== ""
  implicitHeight: visible ? frame.height : 0

  Rectangle {
    id: frame
    width: parent.width
    height: inner.implicitHeight + card.pad * 2
    radius: Style.cornerRadius
    color: card.framed && !card.selfFramed
      ? Qt.rgba(card.foreground.r, card.foreground.g, card.foreground.b, 0.05)
      : "transparent"

    Column {
      id: inner
      x: card.pad
      y: card.pad
      width: parent.width - card.pad * 2
      spacing: Style.spacing.md

      // ---- title, with the entities card's header toggle
      Item {
        visible: card.title !== "" && card.kind !== "heading"
        width: parent.width
        height: visible ? Math.max(titleText.implicitHeight, headerToggle.visible ? headerToggle.height : 0) : 0

        Text {
          id: titleText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: headerToggle.visible ? headerToggle.left : parent.right
          text: (card.block && card.block.icon ? Model.glyph(card.block.icon) + "  " : "") + card.title
          elide: Text.ElideRight
          font.family: card.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          color: card.foreground
        }

        ToggleSwitch {
          id: headerToggle
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: card.kind === "entities" && card.block.headerToggle && card.toggleables().length > 1
          checked: card.anyOn(card.service ? card.service.stateRevision : 0)
          cursorRing: false
          foreground: card.foreground
          onToggled: card.toggleAll()
        }
      }

      Loader {
        id: body
        width: parent.width
        sourceComponent: {
          switch (card.kind) {
          case "entities": return entitiesBody
          case "tiles": return tilesBody
          case "stack": return stackBody
          case "camera": return cameraBody
          case "alarm": return alarmBody
          case "weather": return weatherBody
          case "markdown": return markdownBody
          case "media": return mediaBody
          case "thermostat": return thermostatBody
          case "heading": return headingBody
          case "badges": return badgesBody
          case "map": return card.service && card.service.mapTiles ? realMapBody : mapBody
          case "history": return historyBody
          case "statistic": return statisticBody
          case "logbook": return logbookBody
          case "todo": return todoBody
          case "energy": return energyBody
          case "note": return noteBody
          }
          return null
        }
      }

      Text {
        visible: card.block && card.block.note ? true : false
        width: parent.width
        text: card.block && card.block.note ? "Shown as a list: " + card.block.note + " has no native look here." : ""
        wrapMode: Text.WordWrap
        font.family: card.fontFamily
        font.pixelSize: Style.font.caption
        color: card.dim
      }
    }
  }

  // ---- the entities card's header toggle

  function toggleables() {
    var out = []
    var rows = block && block.rows ? block.rows : []
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].type !== "entity" || !rows[i].entity) continue
      var st = service ? service.stateOf(rows[i].entity, service.stateRevision) : null
      if (Model.hasToggle(st)) out.push(rows[i].entity)
    }
    return out
  }

  function anyOn(revision) {
    var list = toggleables()
    for (var i = 0; i < list.length; i++) {
      if (Model.isOn(service.stateOf(list[i], revision))) return true
    }
    return false
  }

  // HA's rule: anything on means the header switch turns everything off.
  function toggleAll() {
    if (!host) return
    var list = toggleables()
    if (list.length === 0) return
    host.call("homeassistant", anyOn(service.stateRevision) ? "turn_off" : "turn_on", {}, { entity_id: list })
  }

  // ---------------------------------------------------------------- bodies

  Component {
    id: entitiesBody
    Column {
      spacing: 0
      Repeater {
        model: card.block.rows
        EntityRow {
          required property var modelData
          row: modelData
          host: card.host
          stateColor: card.block.stateColor
        }
      }
    }
  }

  Component {
    id: tilesBody
    Column {
      spacing: Style.spacing.md
      Grid {
        id: tileGrid
        width: parent.width
        columns: card.block.columns
        spacing: Style.spacing.md
        readonly property real cellWidth: (width - spacing * (columns - 1)) / columns
        Repeater {
          model: card.block.tiles
          EntityTile {
            required property var modelData
            width: tileGrid.cellWidth
            spec: modelData
            host: card.host
          }
        }
      }
    }
  }

  Component {
    id: stackBody
    Item {
      readonly property int cols: card.block.direction === "horizontal" ? Math.max(1, card.block.children.length)
        : card.block.direction === "grid" ? Math.max(1, card.block.columns || 2) : 1
      implicitHeight: stackGrid.implicitHeight

      Grid {
        id: stackGrid
        width: parent.width
        columns: parent.cols
        spacing: Style.spacing.md
        readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

        Repeater {
          model: card.block.children
          Loader {
            required property var modelData
            width: stackGrid.cellWidth
            source: Qt.resolvedUrl("Card.qml")
            onLoaded: {
              item.width = Qt.binding(function() { return width })
              item.host = card.host
              item.block = modelData
            }
            height: item ? item.implicitHeight : 0
          }
        }
      }
    }
  }

  Component {
    id: cameraBody
    CameraView {
      host: card.host
      entity: card.block.entity
      stateEntity: card.block.stateEntity || card.block.entity
      staticImage: card.block.image
      name: card.block.name
      showName: card.block.showName
      showState: card.block.showState
      entities: card.block.entities
      tapAction: card.block.tapAction
      fit: card.block.fit
    }
  }

  Component {
    id: alarmBody
    AlarmView {
      host: card.host
      entity: card.block.entity
      name: card.block.name
      states: card.block.states
    }
  }

  Component {
    id: weatherBody
    WeatherView {
      host: card.host
      entity: card.block.entity
      name: card.block.name
      showForecast: card.block.showForecast
      showCurrent: card.block.showCurrent
      forecastType: card.block.forecastType
    }
  }

  Component {
    id: markdownBody
    MarkdownView {
      host: card.host
      content: card.block.content
    }
  }

  Component {
    id: mediaBody
    MediaView {
      host: card.host
      entity: card.block.entity
      name: card.block.name
    }
  }

  Component {
    id: thermostatBody
    ThermostatView {
      host: card.host
      entity: card.block.entity
      name: card.block.name
    }
  }

  Component {
    id: headingBody
    Item {
      implicitHeight: Math.max(headingText.implicitHeight, chipsRow.implicitHeight) + Style.spacing.sm
      Text {
        id: headingText
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        text: (card.block.icon ? Model.glyph(card.block.icon) + "  " : "") + card.title
        font.family: card.fontFamily
        font.pixelSize: card.block.style === "subtitle" ? Style.font.body : Style.font.heading
        font.bold: card.block.style !== "subtitle"
        color: card.block.style === "subtitle" ? card.dim : card.foreground
      }
      Row {
        id: chipsRow
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.spacing.sm
        Repeater {
          model: card.block.chips || []
          Chip {
            required property var modelData
            spec: modelData
            host: card.host
          }
        }
      }
    }
  }

  Component {
    id: badgesBody
    Flow {
      spacing: Style.spacing.sm
      Repeater {
        model: card.block.chips
        Chip {
          required property var modelData
          spec: modelData
          host: card.host
        }
      }
    }
  }

  Component {
    id: realMapBody
    MapView {
      host: card.host
      entities: card.block.entities
      defaultZoom: card.block.defaultZoom
      aspect: card.block.aspect
    }
  }

  Component {
    id: historyBody
    HistoryView {
      host: card.host
      entities: card.block.entities
      hours: card.block.hours
      source: card.block.source
      period: card.block.period || "hour"
      statTypes: card.block.statTypes || ["mean", "min", "max"]
      chartType: card.block.chartType || "line"
      minY: card.block.minY === undefined ? null : card.block.minY
      maxY: card.block.maxY === undefined ? null : card.block.maxY
      style: card.block.style || ""
      name: card.block.name || ""
      icon: card.block.icon || ""
    }
  }

  Component {
    id: statisticBody
    StatisticView {
      host: card.host
      entity: card.block.entity
      name: card.block.name
      icon: card.block.icon
      statType: card.block.statType
      period: card.block.period
      unit: card.block.unit
    }
  }

  Component {
    id: logbookBody
    LogbookView {
      host: card.host
      entities: card.block.entities
      hours: card.block.hours
    }
  }

  Component {
    id: todoBody
    TodoView {
      host: card.host
      entity: card.block.entity
    }
  }

  Component {
    id: energyBody
    EnergyView {
      host: card.host
      devices: card.block.devices === true
    }
  }

  // The map with the `mapTiles` setting off: who and what is where, which is
  // most of what one is glanced at for, without asking a tile server.
  Component {
    id: mapBody
    Column {
      readonly property var trackers: {
        var listed = card.block.entities || []
        if (listed.length > 0) return listed
        var out = []
        var store = card.service ? card.service.stateStore : ({})
        var revision = card.service ? card.service.entitySetRevision : 0
        for (var id in store) {
          var domain = Model.domainOf(id)
          if (domain === "person" || domain === "device_tracker") out.push(id)
        }
        return out.sort()
      }
      Repeater {
        model: parent.trackers
        EntityRow {
          required property var modelData
          row: ({ type: "entity", entity: modelData, conditions: [] })
          host: card.host
        }
      }
    }
  }

  Component {
    id: noteBody
    Text {
      text: card.block.text
      wrapMode: Text.WordWrap
      font.family: card.fontFamily
      font.pixelSize: Style.font.caption
      color: card.dim
    }
  }
}
