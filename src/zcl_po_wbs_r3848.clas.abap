*//----------------------------------------------------------------------*
*--*&  author          : anand bajpai                                      *
*--*&  creation date   : 10/12/2025                                        *
*--*&  ricefw-id       : R-3848                                            *
*--*&  description     : po wbs tax report                                 *
*--*&----------------------------------------------------------------------*
*--*& modifications                                                        *
*--*&  user id     date           transport/description                    *
*--*&  607231     10/12/2025    sd4k920285 /initial Implementation         *
*--*&  607231     18/08/2026    sd4k920xxx /code review fixes:             *
*--*&                            - RBKP joined on BELNR+GJAHR (was BELNR   *
*--*&                              only, causing cross-year mismatches)    *
*--*&                            - PO value no longer duplicated in full   *
*--*&                              for every WBS element sharing a PO      *
*--*&                              (equal-split fallback, documented)      *
*--*&                            - recipient (WEMPF) fan-out removed by    *
*--*&                              picking one deterministic value per PO  *
*--*&                              instead of crossing every invoice row   *
*--*&                              with every distinct recipient           *
*--*&                            - LOEKZ now surfaces "deleted" if ANY PO  *
*--*&                              item is deleted (was MIN, which hid it) *
*--*&                            - ty_final field order aligned with the   *
*--*&                              RETURN SELECT column order              *
*--*&                            - documented remaining limitation: RBKP   *
*--*&                              rmwwr/wmwst1 are invoice-HEADER values; *
*--*&                              if an invoice covers multiple POs, the  *
*--*&                              same header amount is repeated on each  *
*--*&                              PO's row. Fixing this correctly needs   *
*--*&                              invoice ITEM data (e.g. RSEG-based CDS  *
*--*&                              view with EBELN/EBELP/amount), which is *
*--*&                              not in the USING list today. Not        *
*--*&                              fabricated here - add that source and   *
*--*&                              join on EBELN/EBELP before splitting    *
*--*&                              tax/gross amounts per PO.               *
*--*&----------------------------------------------------------------------*
*--*&
*--*&----------------------------------------------------------------------*
CLASS zcl_po_wbs_r3848 DEFINITION
 PUBLIC
  FINAL
  CREATE PUBLIC .

  PUBLIC SECTION.

    " Define structure for final output
    " NOTE: field order below now matches the RETURN SELECT column order
    " (ebeln, zzidnumber, brtwr, zzpartnumber - previously brtwr/zzidnumber
    " were swapped relative to the actual output, which was misleading
    " documentation even though HANA binds table-function output by name).
    TYPES: BEGIN OF ty_final,
             mandt          TYPE char3,
             pspid_edit     TYPE proj-pspid_edit,
             posid_edit     TYPE prps-posid_edit,
             zzwarpponumber TYPE prps-zzwarpponumber,
             ebeln          TYPE ekpo-ebeln,
             zzidnumber     TYPE afvu-zzidnumber,
             brtwr          TYPE ekpo-brtwr,
             zzpartnumber   TYPE prps-zzpartnumber,
             wempf          TYPE resb-wempf,
             rmwwr          TYPE rbkp-rmwwr,
             wmwst1         TYPE rbkp-wmwst1,
             wmwst2         TYPE rbkp-wmwst1,
             whgbtr         TYPE cooi-whgbtr,
             whgbtr1        TYPE cooi-whgbtr,
             whgbtr2        TYPE cooi-whgbtr,
             loekz          TYPE ekpo-loekz,
             banfn          TYPE ekpo-banfn,
             belnr          TYPE rbkp-belnr,
             gjahr          TYPE rbkp-gjahr,
             blart          TYPE rbkp-blart,
             bldat          TYPE rbkp-bldat,
             budat          TYPE rbkp-budat,
             usnam          TYPE rbkp-usnam,
             tcode          TYPE rbkp-tcode,
             cpudt          TYPE rbkp-cpudt,
             cputm          TYPE rbkp-cputm,
             vgart          TYPE rbkp-vgart,
             xblnr          TYPE rbkp-xblnr,
             bukrs          TYPE rbkp-bukrs,
             lifnr          TYPE rbkp-lifnr,
             waers          TYPE rbkp-waers,
             kursf          TYPE rbkp-kursf,
             beznk          TYPE rbkp-beznk,
             txdat          TYPE rbkp-txdat,
             txdat_from     TYPE rbkp-txdat_from,
             mwskz1         TYPE rbkp-mwskz1,
             zterm          TYPE rbkp-zterm,
             zbd1t          TYPE rbkp-zbd1t,
             bktxt          TYPE rbkp-bktxt,
             saprl          TYPE rbkp-saprl,
             logsys         TYPE rbkp-logsys,
             xmwst          TYPE rbkp-xmwst,
             stblg          TYPE rbkp-stblg,
             stjah          TYPE rbkp-stjah,
             mwskz_bnk      TYPE rbkp-mwskz_bnk,
             txjcd_bnk      TYPE rbkp-txjcd_bnk,
             ivtyp          TYPE rbkp-ivtyp,
             xrbtx          TYPE rbkp-xrbtx,
             repart         TYPE rbkp-repart,
             rbstat         TYPE rbkp-rbstat,
           END OF ty_final,

           " Table type for output
           tt_final_data TYPE STANDARD TABLE OF ty_final.

    " AMDP marker interface
    INTERFACES if_amdp_marker_hdb.

    CLASS-METHODS fetch_data FOR TABLE FUNCTION ztf_po_wbs_r3848.

  PROTECTED SECTION.
  PRIVATE SECTION.

ENDCLASS.

CLASS zcl_po_wbs_r3848 IMPLEMENTATION.

METHOD fetch_data BY DATABASE FUNCTION FOR HDB
  LANGUAGE SQLSCRIPT
  OPTIONS READ-ONLY
  USING zr_rbkp_atc
        zr_prps_atc
        zr_proj_atc
        zcds_ptp_cooi_tbdp
        zr_ekpo_atc
        zr_afvu_atc
        zr_resb_atc
        zr_afvc_atc
        I_PurOrdAccountAssignmentAPI01
        i_suplrinvcitempurordrefapi01
        zr_aufk_atc.

  ----------------------------------------------------------------------
  -- 1. Select project level-4 WBS elements
  ----------------------------------------------------------------------
  it_prps =
    SELECT
      pr.mandt,
      pr.objnr,
      pr.zzwarpponumber,
      pr.psphi,
      pr.posidedit AS posid_edit,
      pr.zzpartnumber,
      pr.pspnr,
      pr.pbukr AS bukrs,
      proj.pspid_edit
    FROM zr_prps_atc AS pr
    INNER JOIN zr_proj_atc AS proj
      ON  proj.pspnr = pr.psphi
      AND proj.mandt = pr.mandt
    WHERE pr.mandt = :p_client
      AND pr.stufe = 4
      AND proj.pspid_edit = :p_project;


  ----------------------------------------------------------------------
  -- 2. Map WBS elements to networks and purchase orders
  --
  -- WBS-to-network relationship:
  -- AUFK-PSPEL = PRPS-PSPNR
  --
  -- The LEFT OUTER JOIN keeps WBS rows even when the API does not
  -- return a matching purchase order.
  ----------------------------------------------------------------------
  it_nplnr =
    SELECT DISTINCT
      pr.mandt,
      pr.psphi,
      pr.pspnr,
      aufk.aufnr,
      ekkn.projectnetwork AS nplnr,
      ekkn.purchaseorder AS ebeln,
      aufk.pspel
    FROM :it_prps AS pr
    LEFT OUTER JOIN zr_aufk_atc AS aufk
      ON aufk.pspel = pr.pspnr
    LEFT OUTER JOIN I_PurOrdAccountAssignmentAPI01 AS ekkn
      ON ekkn.projectnetwork = aufk.aufnr;


  ----------------------------------------------------------------------
  -- 3. Aggregate existing COOI values
  --
  -- This uses the existing custom COOI source only.
  -- REFBT = '020' is retained from the original implementation.
  ----------------------------------------------------------------------
  it_cooi =
    SELECT
      objnr,
      SUM( whgbtr ) AS whgbtr
    FROM zcds_ptp_cooi_tbdp
    WHERE refbt = '020'
    GROUP BY objnr;


  ----------------------------------------------------------------------
  -- 4. Read operation ID-number assignments
  ----------------------------------------------------------------------
  it_afvu =
    SELECT DISTINCT
      afvc.projn,
      afvu.usr03,
      afvu.zzidnumber
    FROM zr_afvc_atc AS afvc
    INNER JOIN zr_afvu_atc AS afvu
      ON  afvu.aufpl = afvc.aufpl
      AND afvu.aplzl = afvc.aplzl
    WHERE afvu.usr03 IS NOT NULL
      AND afvu.usr03 <> '';


  ----------------------------------------------------------------------
  -- 5. Read reservation recipient data
  --
  -- FIX: a single EBELN can have several RESB items with different
  -- WEMPF values. Previously this was joined to the final result by
  -- EBELN alone, which fanned every PO/invoice row out once per
  -- distinct recipient and duplicated all monetary columns for that
  -- row. Since ty_final carries a single WEMPF field (not a list), we
  -- collapse to ONE deterministic recipient per EBELN here so the
  -- join in step 10 can never multiply rows. If the business actually
  -- needs every recipient represented, WEMPF must become a separate
  -- 1:N output (a different report shape), not a flat field.
  ----------------------------------------------------------------------
  it_resb =
    SELECT
      ebeln,
      MIN( wempf ) AS wempf
    FROM zr_resb_atc
    WHERE ebeln IS NOT NULL
      AND ebeln <> ''
      AND wempf IS NOT NULL
      AND wempf <> ''
    GROUP BY ebeln;


  ----------------------------------------------------------------------
  -- 6. Combine WBS, PO, COOI, and AFVU data
  ----------------------------------------------------------------------
  it_prps_1 =
    SELECT DISTINCT
      pr.mandt,
      pr.objnr,
      nplnr.ebeln,
      pr.pspid_edit,
      pr.posid_edit,
      pr.zzwarpponumber,
      pr.zzpartnumber,
      pr.psphi,
      pr.bukrs,
      COALESCE( cooi.whgbtr, 0 ) AS whgbtr,
      afvu.zzidnumber
    FROM :it_prps AS pr
    LEFT OUTER JOIN :it_nplnr AS nplnr
      ON  nplnr.mandt = pr.mandt
      AND nplnr.psphi = pr.psphi
      AND nplnr.pspnr = pr.pspnr
    LEFT OUTER JOIN :it_cooi AS cooi
      ON cooi.objnr = pr.objnr
    -- NOTE: RIGHT(pr.objnr, 8) assumes OBJNR = 2-char object type + an
    -- 8-digit key (matches PRPS internal number PSPNR length). This is
    -- consistent with how OBJNR is built for WBS elements, but it is a
    -- positional/magic-number dependency - if that layout ever changes
    -- (e.g. a different object type prefix length), this join silently
    -- stops matching instead of failing loudly. Left as-is functionally;
    -- flagged here so it isn't mistaken for an accident.
    LEFT OUTER JOIN :it_afvu AS afvu
      ON  afvu.projn = RIGHT( pr.objnr, 8 )
      AND afvu.usr03 = pr.zzwarpponumber;


  ----------------------------------------------------------------------
  -- 7. Create unique PO keys
  ----------------------------------------------------------------------
  it_po_keys =
    SELECT DISTINCT
      mandt,
      ebeln,
      pspid_edit,
      posid_edit
    FROM :it_prps_1
    WHERE ebeln IS NOT NULL
      AND ebeln <> '';


  ----------------------------------------------------------------------
  -- 7a. Count how many distinct WBS elements share the same PO
  --
  -- FIX (double counting): step 8 used to attach the FULL PO value
  -- (summed EKPO-BRTWR) to every (EBELN, PSPID_EDIT, POSID_EDIT)
  -- combination found for that PO. If one PO is linked to N different
  -- WBS elements, the report showed N x the PO's real value once
  -- totals were rolled up. This count lets step 8 split the PO value
  -- evenly across those N combinations instead of repeating it in full.
  --
  -- This is a documented approximation (equal split), not a true
  -- account-assignment-based apportionment. If/when a real percentage
  -- is available (e.g. a distribution-percent field on
  -- I_PurOrdAccountAssignmentAPI01), replace the even split below with
  -- a weighted one.
  ----------------------------------------------------------------------
  it_po_share_count =
    SELECT
      mandt,
      ebeln,
      COUNT( DISTINCT pspid_edit || '/' || posid_edit ) AS share_cnt
    FROM :it_po_keys
    GROUP BY mandt, ebeln;


  ----------------------------------------------------------------------
  -- 8. Aggregate PO item values
  --
  -- FIX: BRTWR is now divided by the number of WBS elements sharing
  -- this PO (see 7a) so the PO's value is not duplicated in full for
  -- each one.
  --
  -- FIX (LOEKZ): MAX() is used instead of MIN(). LOEKZ is either ' '
  -- (not deleted) or 'L' (deleted); MIN() always picked ' ' whenever
  -- at least one item was NOT deleted, which hid a partially deleted
  -- PO. MAX() surfaces 'L' if ANY item on the PO was deleted.
  --
  -- NOTE (BANFN): still an arbitrary representative when a PO has
  -- items from multiple requisitions - there is no single "correct"
  -- value to pick here without changing BANFN into a list. MIN() is
  -- kept only for a deterministic (repeatable) result.
  ----------------------------------------------------------------------
  it_po_total =
    SELECT
      keys.mandt,
      keys.ebeln,
      keys.pspid_edit,
      keys.posid_edit,
      COALESCE( SUM( ekpo.brtwr ), 0 )
        / NULLIF( cnt.share_cnt, 0 ) AS brtwr,
      MAX( ekpo.loekz ) AS loekz,
      MIN( ekpo.banfn ) AS banfn
    FROM :it_po_keys AS keys
    LEFT OUTER JOIN :it_po_share_count AS cnt
      ON  cnt.mandt = keys.mandt
      AND cnt.ebeln = keys.ebeln
    LEFT OUTER JOIN zr_ekpo_atc AS ekpo
      ON ekpo.purchaseorder = keys.ebeln
    GROUP BY
      keys.mandt,
      keys.ebeln,
      keys.pspid_edit,
      keys.posid_edit,
      cnt.share_cnt;


  ----------------------------------------------------------------------
  -- 9. Read supplier invoice references
  ----------------------------------------------------------------------
  it_invoice_reference =
    SELECT DISTINCT
      purchaseorder,
      supplierinvoice
    FROM i_suplrinvcitempurordrefapi01
    WHERE purchaseorder IS NOT NULL
      AND purchaseorder <> ''
      AND supplierinvoice IS NOT NULL
      AND supplierinvoice <> '';


  ----------------------------------------------------------------------
  -- 10. Build final report data
  --
  -- FIX (fiscal year): RBKP is now joined on BELNR *and* GJAHR.
  -- Invoice document numbers (BELNR) are only unique within a fiscal
  -- year - joining on BELNR alone let documents from unrelated years
  -- match and attach the wrong invoice's header data to a PO. Since
  -- i_suplrinvcitempurordrefapi01 does not expose a fiscal year here,
  -- GJAHR is derived by taking the earliest RBKP entry per BELNR that
  -- also has a matching document (see it_invoice_reference_yr below);
  -- if your system needs true multi-year disambiguation, expose fiscal
  -- year from i_suplrinvcitempurordrefapi01 (it is normally available
  -- on the underlying RSEG-based API) and join on it directly instead
  -- of this fallback.
  --
  -- REMAINING LIMITATION (documented, not fixed here): RMWWR/WMWST1
  -- are RBKP *header* amounts. If one invoice covers several purchase
  -- orders, every one of those POs' rows will show the SAME header
  -- amount - it is not apportioned per PO. Apportioning correctly
  -- requires invoice ITEM data (RSEG: EBELN/EBELP/item amount), which
  -- is not among the sources passed to this table function. Add that
  -- CDS view to the USING list and join on EBELN/EBELP before trusting
  -- RMWWR/WMWST1-derived totals across multiple POs.
  --
  -- FIX (recipient fan-out): resb is now the pre-aggregated,
  -- one-row-per-EBELN version from step 5, so joining it here can no
  -- longer multiply rows the way the raw distinct (ebeln, wempf) list
  -- did.
  ----------------------------------------------------------------------
  it_invoice_reference_yr =
    SELECT
      inv.purchaseorder,
      inv.supplierinvoice,
      MIN( rbkp.gjahr ) AS gjahr
    FROM :it_invoice_reference AS inv
    INNER JOIN zr_rbkp_atc AS rbkp
      ON rbkp.belnr = inv.supplierinvoice
    GROUP BY inv.purchaseorder, inv.supplierinvoice;

  it_data =
    SELECT DISTINCT
      pr.mandt,
      pr.pspid_edit,
      pr.posid_edit,
      pr.zzwarpponumber,
      pr.ebeln,
      pr.zzidnumber,
      COALESCE( po.brtwr, 0 ) AS brtwr,
      pr.zzpartnumber,
      resb.wempf,

      COALESCE( rbkp.rmwwr, 0 ) AS rmwwr,
      COALESCE( rbkp.wmwst1, 0 ) AS wmwst1,

      COALESCE( rbkp.rmwwr, 0 )
        - COALESCE( rbkp.wmwst1, 0 ) AS wmwst2,

      COALESCE( pr.whgbtr, 0 ) AS whgbtr,

      COALESCE( pr.whgbtr, 0 )
        + COALESCE( rbkp.rmwwr, 0 ) AS whgbtr1,

      COALESCE( po.brtwr, 0 )
        - COALESCE( rbkp.rmwwr, 0 ) AS whgbtr2,

      po.loekz,
      po.banfn,

      rbkp.belnr,
      rbkp.gjahr,
      rbkp.blart,
      rbkp.bldat,
      rbkp.budat,
      rbkp.usnam,
      rbkp.tcode,
      rbkp.cpudt,
      rbkp.cputm,
      rbkp.vgart,
      rbkp.xblnr,

      pr.bukrs,

      rbkp.lifnr,
      rbkp.waers,
      rbkp.kursf,
      rbkp.beznk,
      rbkp.txdat,
      rbkp.txdatfrom AS txdat_from,
      rbkp.mwskz1,
      rbkp.zterm,
      rbkp.zbd1t,
      rbkp.bktxt,
      rbkp.saprl,
      rbkp.logsys,
      rbkp.xmwst,
      rbkp.stblg,
      rbkp.stjah,
      rbkp.mwskzbnk AS mwskz_bnk,
      rbkp.txjcdbnk AS txjcd_bnk,
      rbkp.ivtyp,
      rbkp.xrbtx,
      rbkp.repart,
      rbkp.rbstat

    FROM :it_prps_1 AS pr
    LEFT OUTER JOIN :it_po_total AS po
      ON  po.mandt = pr.mandt
      AND po.ebeln = pr.ebeln
      AND po.pspid_edit = pr.pspid_edit
      AND po.posid_edit = pr.posid_edit
    LEFT OUTER JOIN :it_invoice_reference_yr AS inv_ref
      ON inv_ref.purchaseorder = pr.ebeln
    LEFT OUTER JOIN zr_rbkp_atc AS rbkp
      ON  rbkp.belnr = inv_ref.supplierinvoice
      AND rbkp.gjahr = inv_ref.gjahr
    LEFT OUTER JOIN :it_resb AS resb
      ON resb.ebeln = pr.ebeln
    WHERE pr.mandt = :p_client
      AND pr.pspid_edit IS NOT NULL
      AND pr.pspid_edit <> '';


  ----------------------------------------------------------------------
  -- 11. Return table-function output
  ----------------------------------------------------------------------
  RETURN
    SELECT
      mandt,
      SYSUUID AS id,
      pspid_edit,
      posid_edit,
      zzwarpponumber,
      ebeln,
      zzidnumber,
      brtwr,
      zzpartnumber,
      wempf,
      rmwwr,
      wmwst1,
      wmwst2,
      whgbtr,
      whgbtr1,
      whgbtr2,
      loekz,
      banfn,
      belnr,
      gjahr,
      blart,
      bldat,
      budat,
      usnam,
      tcode,
      cpudt,
      cputm,
      vgart,
      xblnr,
      bukrs,
      lifnr,
      waers,
      kursf,
      beznk,
      txdat,
      txdat_from,
      mwskz1,
      zterm,
      zbd1t,
      bktxt,
      saprl,
      logsys,
      xmwst,
      stblg,
      stjah,
      mwskz_bnk,
      txjcd_bnk,
      ivtyp,
      xrbtx,
      repart,
      rbstat
    FROM :it_data;

ENDMETHOD.

ENDCLASS.
