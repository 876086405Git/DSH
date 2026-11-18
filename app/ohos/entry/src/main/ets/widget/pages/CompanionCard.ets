// 伙伴小屋 on the home screen, as Android's companion_widget.xml draws it: the pixel whale,
// her name and how well she knows you, what she is doing, the last thing she said.
// CompanionFormAbility binds widgetView's fields; tapping opens the room.

const storage: LocalStorage = new LocalStorage();

@Entry(storage)
@Component
struct CompanionCard {
  @LocalStorageProp('ready') ready: boolean = false;
  @LocalStorageProp('name') name: string = '';
  @LocalStorageProp('nameDefault') nameDefault: boolean = true;
  @LocalStorageProp('status') status: string = '';
  @LocalStorageProp('statusDefault') statusDefault: string = 'waiting';
  @LocalStorageProp('line') line: string = '';
  @LocalStorageProp('pearls') pearls: string = '';
  @LocalStorageProp('pose') pose: string = 'idle';
  @LocalStorageProp('openUri') openUri: string = 'dshgo://open/companion';

  private whale(): Resource {
    if (this.pose === 'sleeping') return $r('app.media.companion_widget_sleeping');
    if (this.pose === 'happy') return $r('app.media.companion_widget_happy');
    return $r('app.media.companion_widget_idle');
  }

  private statusText(): ResourceStr {
    if (this.statusDefault === 'asleep') return $r('app.string.companion_widget_asleep');
    if (this.statusDefault === 'waiting') return $r('app.string.companion_widget_waiting');
    return this.status;
  }

  build() {
    Row() {
      Image(this.whale())
        .width(64)
        .height(64)
        .objectFit(ImageFit.Contain)
        .interpolation(ImageInterpolation.None)
      Column() {
        Row() {
          Text(this.nameDefault ? $r('app.string.companion_widget_name') : this.name)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFF2FBFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
          if (this.pearls.length > 0) {
            Text(this.pearls)
              .fontSize(10)
              .fontColor('#FFFF9DB5')
              .maxLines(1)
              .margin({ left: 6 })
          }
        }
        .width('100%')
        // Until the saved room is read, only her name and the waiting line show.
        Text(this.ready ? this.statusText() : $r('app.string.companion_widget_waiting'))
          .fontSize(12)
          .fontColor('#FF9FD8F2')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 1 })
        if (this.ready && this.line.length > 0) {
          Text(this.line)
            .fontSize(13)
            .fontColor('#E6F2FBFF')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 8 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 10, top: 8, right: 16, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    // The room's deep water, as on the stage at night.
    .linearGradient({ angle: 180, colors: [['#FF1C5A8C', 0], ['#FF0D2F55', 1]] })
    .onClick((): void => {
      postCardAction(this, { action: 'router', uri: this.openUri, params: {} });
    })
  }
}
