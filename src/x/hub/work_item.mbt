///| Work item operations

///|
fn include_kind(item_kind : WorkItemKind, kind : WorkItemKind?) -> Bool {
  match kind {
    None => true
    Some(value) => item_kind == value
  }
}

///|
fn include_state(item_state : WorkItemState, state : WorkItemState?) -> Bool {
  match state {
    None => true
    Some(value) => item_state == value
  }
}

///|
pub fn Hub::get_work_item(
  self : Hub,
  objects : &@lib.ObjectStore,
  work_item_id : String,
) -> WorkItem? {
  let record = self.store.get_record(objects, work_item_meta_key(work_item_id))
  match record {
    None => None
    Some(r) => {
      if not(is_work_item_record_kind(r.kind)) {
        return None
      }
      let result : Result[WorkItem, PrError] = try? parse_work_item(r.payload)
      match result {
        Ok(item) => Some(item)
        Err(_) => None
      }
    }
  }
}

///|
pub fn Hub::list_work_items(
  self : Hub,
  objects : &@lib.ObjectStore,
  state? : WorkItemState? = None,
  kind? : WorkItemKind? = None,
) -> Array[WorkItem] {
  let result : Array[WorkItem] = []
  let records = self.store.list_records(objects, work_item_meta_prefix())
  for record in records {
    if not(record.key.has_suffix("/meta")) {
      continue
    }
    if not(is_work_item_record_kind(record.kind)) {
      continue
    }
    let parsed : Result[WorkItem, PrError] = try? parse_work_item(
      record.payload,
    )
    guard parsed is Ok(item) else { continue }
    if not(include_kind(item.kind(), kind)) {
      continue
    }
    if not(include_state(item.state(), state)) {
      continue
    }
    result.push(item)
  }
  result.sort_by(fn(a, b) {
    if a.created_at < b.created_at {
      -1
    } else if a.created_at > b.created_at {
      1
    } else {
      0
    }
  })
  result
}
